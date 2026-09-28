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
        XCTAssertEqual(config.sttBaseURL, "http://127.0.0.1:8090")
        XCTAssertEqual(config.llmBaseURL, "http://127.0.0.1:8091/v1")
        XCTAssertEqual(config.llmModel, "qwen2.5-1.5b-instruct")
        XCTAssertEqual(config.llmReasoningEffort, "")
        XCTAssertEqual(config.hotkey, HotkeySpec.named("right_option"))
        XCTAssertEqual(config.hotkey.keyCode, 0x3D)
        XCTAssertEqual(config.replacements.count, 0)
        XCTAssertTrue(config.debugEnabled)
    }

    func testReplacementsAndFn() throws {
        let text = """
        [stt]
        base_url = "http://127.0.0.1:8090"
        model = "/tmp/model"
        language = "en"

        [llm]
        base_url = "http://127.0.0.1:8000/v1"
        model = "small"
        reasoning_effort = ""

        [hotkey]
        key = "fn"
        mode = "hold"

        [replacements]
        "em el ex" = "MLX"
        # ignored
        quote = "say \\"hi\\""
        """
        let config = try ConfigFile.parse(text)
        XCTAssertEqual(config.hotkey.keyCode, 0x3F)
        XCTAssertEqual(config.hotkey.modifierBit, 1 << 23)
        XCTAssertEqual(config.replacements.count, 2)
        XCTAssertEqual(config.replacements[0].0, "em el ex")
        XCTAssertEqual(config.replacements[0].1, "MLX")
        XCTAssertEqual(config.replacements[1].1, "say \"hi\"")
        XCTAssertEqual(config.llmReasoningEffort, "")
    }

    func testHoldToggleIgnoresOtherKeys() {
        var tracker = HoldTracker()
        let spec = HotkeySpec.named("right_option")!
        XCTAssertEqual(tracker.handle(keyCode: 0x3A, spec: spec), nil)
        XCTAssertEqual(tracker.handle(keyCode: spec.keyCode, spec: spec), .pressed)
        XCTAssertEqual(tracker.handle(keyCode: spec.keyCode, spec: spec), .released)
        XCTAssertFalse(tracker.holding)
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
