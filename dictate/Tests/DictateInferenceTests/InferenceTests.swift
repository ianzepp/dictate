import Foundation
import XCTest
import DictateCore
@testable import DictateInference

final class InferenceTests: XCTestCase {
    func testCanceledQueuedOwnerDoesNotConsumeGate() async throws {
        let gate = SerialGate()
        try await gate.acquire()
        let canceled = Task { try await gate.acquire() }
        // Cancellation is valid both before and after the waiter registers.
        canceled.cancel()
        do { try await canceled.value; XCTFail("Canceled owner acquired gate") }
        catch is CancellationError { }
        await gate.release()
        try await gate.acquire()
        await gate.release()
    }

    func testDisabledCleanupDoesNotSwallowCancellation() async throws {
        let config = try ConfigFile.parse("[speech]\nmodel = \"/missing/model\"\n[cleanup]\nenabled = false\n")
        let engine = InferenceEngine(config: config, configURL: URL(fileURLWithPath: "/missing/config.toml"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.cleanup(text: "keep this text")
        }
        do { _ = try await task.value; XCTFail("Cancellation became successful fallback") }
        catch is CancellationError { }
    }

    func testLocalMissingModelIsNotConvertedToDownload() async throws {
        let resolver = ModelResolver(root: URL(fileURLWithPath: "/tmp/dictate-test-models"))
        XCTAssertFalse(resolver.requiresDownload("/tmp/dictate-test-models/missing"))
        do { _ = try await resolver.resolve("/tmp/dictate-test-models/missing"); XCTFail("Missing model accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("config.json")) }
    }

    func testMissingLocalModelPublishesFailureWithoutRetrySleep() async throws {
        let config = try ConfigFile.parse("[speech]\nmodel = \"/missing/model\"\n[cleanup]\nenabled = false\n")
        let engine = InferenceEngine(config: config, configURL: URL(fileURLWithPath: "/missing/config.toml"))
        await engine.prepare()
        let status = await engine.status()
        XCTAssertEqual(status.speech.state, .failed)
        XCTAssertTrue(status.speech.detail.contains("config.json"))
        XCTAssertEqual(status.cleanup.state, .off)
        let result = try await engine.cleanup(text: "Keep this text.")
        XCTAssertEqual(result.text, "Keep this text.")
        XCTAssertFalse(result.used)
    }

    func testMissingCleanupModelKeepsTranscript() async throws {
        let config = try ConfigFile.parse("[speech]\nmodel = \"/missing/speech\"\n[cleanup]\nmodel = \"/missing/cleanup\"\nenabled = true\n")
        let engine = InferenceEngine(config: config, configURL: URL(fileURLWithPath: "/missing/config.toml"))
        let source = "First open the project folder and read the setup note before changing anything. Then check the saved device name and keep the original logs."
        let result = try await engine.cleanup(text: source)
        XCTAssertEqual(result.text, source)
        XCTAssertFalse(result.used)
    }

    func testModelValidationRejectsTruncatedWeightsAndMissingShards() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["config.json", "tokenizer.json", "tokenizer_config.json"] {
            try Data("{}".utf8).write(to: directory.appendingPathComponent(name))
        }
        let header = Data("{\"weight\":{\"dtype\":\"F32\",\"shape\":[1],\"data_offsets\":[0,4]}}".utf8)
        var length = UInt64(header.count).littleEndian
        var weight = withUnsafeBytes(of: &length) { Data($0) }
        weight.append(header)
        let path = directory.appendingPathComponent("model.safetensors")
        try weight.write(to: path)
        XCTAssertThrowsError(try ModelResolver.validate(directory))
        weight.append(Data(repeating: 0, count: 4))
        try weight.write(to: path)
        XCTAssertNoThrow(try ModelResolver.validate(directory))
        try Data("{\"weight_map\":{\"weight\":\"missing.safetensors\"}}".utf8)
            .write(to: directory.appendingPathComponent("model.safetensors.index.json"))
        XCTAssertThrowsError(try ModelResolver.validate(directory))
    }
}
