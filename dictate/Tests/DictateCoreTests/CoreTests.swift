import DictateCore
import XCTest

final class CoreTests: XCTestCase {
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

    func testDuckSilencesAndRespectsTheUser() {
        XCTAssertEqual(Duck.level(from: 0.5), 0)
        XCTAssertTrue(Duck.shouldRestore(current: 0.0625, ducked: 0.0625))
        // The user turned it up while recording: leave their volume alone.
        XCTAssertFalse(Duck.shouldRestore(current: 0.4, ducked: 0.0625))
    }

    func testFadeMovesLinearlyAndEndsOnTarget() {
        XCTAssertEqual(Duck.fade(from: 0.5, to: 0.05, elapsed: 0, duration: 0.15), 0.5, accuracy: 0.0001)
        XCTAssertEqual(Duck.fade(from: 0.5, to: 0.05, elapsed: 0.075, duration: 0.15), 0.275, accuracy: 0.0001)
        XCTAssertEqual(Duck.fade(from: 0.5, to: 0.05, elapsed: 0.2, duration: 0.15), 0.05)
        XCTAssertEqual(Duck.fade(from: 0.1, to: 0.6, elapsed: 1, duration: 0), 0.6)
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

}
