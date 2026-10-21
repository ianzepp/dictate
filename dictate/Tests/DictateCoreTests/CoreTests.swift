import DictateCore
import XCTest

final class CoreTests: XCTestCase {
    func testExampleConfig() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("config.example.toml"), encoding: .utf8)
        let config = try ConfigFile.parse(text)
        XCTAssertEqual(config.serviceURL, "http://127.0.0.1:8090")
        XCTAssertEqual(config.hotkey, HotkeySpec.named("fn"))
        XCTAssertEqual(config.hotkey.keyCode, 0x3F)
        XCTAssertEqual(config.hotkey.modifierBit, 1 << 23)
        XCTAssertEqual(config.lockKey, HotkeySpec.named("right_option"))
        XCTAssertFalse(config.debugEnabled)
    }

    func testReadsOnlyWhatTheAppUses() throws {
        let text = """
        [speech]
        model = "owner/model"
        port = 9100

        [cleanup]
        enabled = false
        future_key = [1, 2]

        [hotkey]
        key = "right_option"

        [debug]
        enabled = true

        [replacements]
        "em el ex" = "MLX"
        """
        let config = try ConfigFile.parse(text)
        XCTAssertEqual(config.serviceURL, "http://127.0.0.1:9100")
        XCTAssertEqual(config.hotkey, HotkeySpec.named("right_option"))
        XCTAssertTrue(config.debugEnabled)
    }

    func testRightOptionToTalkRightCommandToLock() throws {
        let config = try ConfigFile.parse("[hotkey]\nkey = \"right_option\"\nlock = \"right_command\"\n")
        XCTAssertEqual(config.hotkey, HotkeySpec.named("right_option"))
        XCTAssertEqual(config.lockKey, HotkeySpec.named("right_command"))
    }

    func testDefaultsAndBadValues() throws {
        let empty = try ConfigFile.parse("[speech]\nmodel = \"a/b\"\n")
        XCTAssertEqual(empty.speechPort, ConfigFile.defaultSpeechPort)
        XCTAssertEqual(empty.hotkey, HotkeySpec.named("fn"))
        XCTAssertThrowsError(try ConfigFile.parse("[hotkey]\nkey = \"f13\"\n"))
        XCTAssertThrowsError(try ConfigFile.parse("[speech]\nport = 80\n"))
        XCTAssertNil(try ConfigFile.parse("[hotkey]\nlock = \"none\"\n").lockKey)
        XCTAssertNil(try ConfigFile.parse("[hotkey]\nkey = \"right_option\"\n").lockKey)
        XCTAssertThrowsError(try ConfigFile.parse("[hotkey]\nkey = \"right_option\"\nlock = \"right_option\"\n"))
        XCTAssertThrowsError(try ConfigFile.parse("[debug]\nenabled = \"yes\"\n"))
    }

    func testHoldFollowsTheKeyBit() {
        var tracker = HoldTracker()
        let spec = HotkeySpec.named("right_option")!
        let left: UInt = 0x20, right: UInt = 0x40
        XCTAssertEqual(tracker.handle(keyCode: 0x3A, flags: left, spec: spec), nil)
        XCTAssertEqual(tracker.handle(keyCode: spec.keyCode, flags: left | right, spec: spec), .pressed)
        // Left option still down must not keep right option held.
        XCTAssertEqual(tracker.handle(keyCode: spec.keyCode, flags: left, spec: spec), .released)
        XCTAssertFalse(tracker.holding)
    }

    func testMissedEventsCorrectThemselves() {
        var tracker = HoldTracker()
        let spec = HotkeySpec.named("fn")!
        let fn: UInt = 1 << 23
        XCTAssertEqual(tracker.handle(keyCode: 0x3F, flags: fn, spec: spec), .pressed)
        // The release was missed; the next press is not mistaken for a release.
        XCTAssertEqual(tracker.handle(keyCode: 0x3F, flags: fn, spec: spec), nil)
        XCTAssertEqual(tracker.check(flags: fn, spec: spec), nil)
        XCTAssertEqual(tracker.check(flags: 0, spec: spec), .released)
        XCTAssertEqual(tracker.check(flags: 0, spec: spec), nil)
    }

    func testSilenceHasNoSpeech() {
        let second = 16000
        XCTAssertFalse(Speech.hasSpeech([Int16](repeating: 0, count: second)))
        // Room noise around -60 dBFS.
        XCTAssertFalse(Speech.hasSpeech((0..<second).map { $0 % 2 == 0 ? 33 : -33 }))
        // 0.1 s of a -20 dBFS tone is a click, not speech.
        let click = (0..<second).map { $0 < second / 10 ? Int16($0 % 2 == 0 ? 3277 : -3277) : 0 }
        XCTAssertFalse(Speech.hasSpeech(click))
        let talk = (0..<second).map { $0 < second / 2 ? Int16($0 % 2 == 0 ? 3277 : -3277) : 0 }
        XCTAssertTrue(Speech.hasSpeech(talk))
        XCTAssertEqual(Speech.voicedSeconds(talk), 0.5, accuracy: 0.03)
    }

    func testHealthParse() {
        let body = Data(#"{"status":"ok","speech":{"state":"downloading","detail":"Downloading a/b"},"cleanup":{"state":"missing","detail":"llama-server missing"}}"#.utf8)
        let health = ServiceHealth.parse(body)
        XCTAssertEqual(health?.speech, .init(state: "downloading", detail: "Downloading a/b"))
        XCTAssertEqual(health?.cleanup.state, "missing")
        // An older service without the state fields reads as unknown, not as healthy.
        XCTAssertNil(ServiceHealth.parse(Data(#"{"status":"ok"}"#.utf8)))
    }

    func testMenuPreviewWrapsTwoLinesThenEllipsizes() {
        XCTAssertEqual(MenuPreview.lines("Hello.", width: 10), ["Hello."])
        XCTAssertEqual(MenuPreview.lines("one two three four", width: 10), ["one two", "three four"])
        let long = MenuPreview.lines("one two three four five", width: 10)
        XCTAssertEqual(long.count, 2)
        XCTAssertEqual(long[0], "one two")
        XCTAssertTrue(long[1].hasSuffix("…"))
        XCTAssertLessThanOrEqual(long[1].count, 10)
    }

    func testWavHeader() {
        let data = Wav.pcm16Mono(samples: [1, -1], sampleRate: 16000)
        XCTAssertEqual(data.count, 48)
        XCTAssertEqual(Array(data.prefix(4)), [0x52, 0x49, 0x46, 0x46])
        XCTAssertEqual(data[22], 1) // mono
        XCTAssertEqual(data[34], 16) // bits per sample
    }

    func testMultipartContainsPayload() {
        let body = Multipart.body(filename: "dictation.wav", mime: "audio/wav", payload: Data([1, 2, 3]), boundary: "BOUND")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"audio_file\""))
        XCTAssertTrue(text.contains("filename=\"dictation.wav\""))
        XCTAssertTrue(body.contains(Data([1, 2, 3])))
    }
}
