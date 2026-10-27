import Foundation
import DictateCore
import DictateInference

/// Fixture runner deliberately shares the app's production engine. No audio
/// recording, microphone permission, pasteboard, or synthetic model adapter.
@main
struct DictateVerify {
    static func main() async {
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch {
            FileHandle.standardError.write(Data("DictateVerify: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func run(_ args: [String]) async throws {
        guard let first = args.first, args.count >= 1, first != "--help" else {
            FileHandle.standardOutput.write(Data("Usage: DictateVerify CONFIG [AUDIO.wav ...] [--cleanup-fixtures CASES.json] [--cancel-cleanup] [--cancel-recognition AUDIO.wav] [--check-replacement-reload AUDIO.wav]\n".utf8))
            return
        }
        let configURL = URL(fileURLWithPath: first)
        let configText = try String(contentsOf: configURL, encoding: .utf8)
        let config = try ConfigFile.parse(configText)
        // Exercise production live-reload with an isolated copy. Per-fixture
        // replacement prompts must match the original spike, without writing
        // to the operator's app configuration or reloading resident models.
        let fixtureConfig = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictate-verify-\(UUID().uuidString).toml")
        try configText.write(to: fixtureConfig, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fixtureConfig) }
        let engine = InferenceEngine(config: config, configURL: fixtureConfig)
        let began = ProcessInfo.processInfo.systemUptime
        await engine.prepare()
        let status = await engine.status()
        try emit(["event": "prepared", "speech": status.speech.state.rawValue,
                  "speech_detail": status.speech.detail, "cleanup": status.cleanup.state.rawValue,
                  "cleanup_detail": status.cleanup.detail,
                  "seconds": ProcessInfo.processInfo.systemUptime - began])
        guard status.speech.state == .ready, !config.cleanupEnabled || status.cleanup.state == .ready else {
            throw VerificationFailure("Required model preparation failed")
        }
        var index = 1
        while index < args.count {
            switch args[index] {
            case "--cleanup-fixtures":
                index += 1
                guard index < args.count else { throw VerificationFailure("Missing cleanup fixture path") }
                let fixtures = try JSONDecoder().decode(Fixtures.self,
                    from: Data(contentsOf: URL(fileURLWithPath: args[index])))
                for test in fixtures.cases {
                    guard test.replacements.allSatisfy({ $0.count == 2 }) else {
                        throw VerificationFailure("Fixture replacement must have two strings")
                    }
                    let pairs = test.replacements.map { Replacement(source: $0[0], replacement: $0[1]) }
                    try replacingPairs(in: configText, with: pairs)
                        .write(to: fixtureConfig, atomically: true, encoding: .utf8)
                    let source = CleanupRules.replacements(test.source, pairs: pairs)
                    let result = try await engine.cleanup(text: source)
                    try emit(["event": "cleanup", "id": test.id, "source": source,
                              "text": result.text, "used": result.used, "seconds": result.seconds])
                }
                try configText.write(to: fixtureConfig, atomically: true, encoding: .utf8)
            case "--cancel-cleanup":
                try await verifyCleanupCancellation(engine)
            case "--check-replacement-reload":
                index += 1
                guard index < args.count else { throw VerificationFailure("Missing replacement-reload WAV path") }
                try await verifyReplacementReload(engine, wav: Data(contentsOf: URL(fileURLWithPath: args[index])),
                    fixtureConfig: fixtureConfig, configText: configText, config: config)
            case "--cancel-recognition":
                index += 1
                guard index < args.count else { throw VerificationFailure("Missing cancellation WAV path") }
                let wav = try Data(contentsOf: URL(fileURLWithPath: args[index]))
                let request = Task { try await engine.recognize(wav: wav) }
                try await Task.sleep(nanoseconds: 150_000_000)
                request.cancel()
                do { _ = try await request.value; throw VerificationFailure("Canceled recognition returned a result") }
                catch is CancellationError { }
                let following = try await engine.recognize(wav: wav)
                guard !following.raw.isEmpty else { throw VerificationFailure("Recognition failed after cancellation") }
                try emit(["event": "recognition_cancellation", "discarded": true,
                          "following_text": following.raw, "following_seconds": following.seconds])
            default:
                let path = args[index]
                let result = try await engine.recognize(wav: Data(contentsOf: URL(fileURLWithPath: path)))
                let cleaned = try await engine.cleanup(text: result.replaced)
                try emit(["event": "transcript", "audio": path, "raw": result.raw,
                          "replaced": result.replaced, "text": cleaned.text, "cleanup_used": cleaned.used,
                          "recognition_seconds": result.seconds, "cleanup_seconds": cleaned.seconds])
            }
            index += 1
        }
    }

    private static func verifyCleanupCancellation(_ engine: InferenceEngine) async throws {
        let source = "um first open the project folder and read the short setup note before changing anything in the configuration. Then check which service owns the microphone and confirm that the saved device name still matches the laptop."
        let request = Task { try await engine.cleanup(text: source) }
        try await Task.sleep(nanoseconds: 150_000_000)
        request.cancel()
        do { _ = try await request.value; throw VerificationFailure("Canceled cleanup returned a result") }
        catch is CancellationError { }
        let following = try await engine.cleanup(text: "um i think we should bring the blue folder.")
        guard following.used else { throw VerificationFailure("Model did not generate after cancellation") }
        try emit(["event": "cleanup_cancellation", "discarded": true,
                  "following_text": following.text, "following_used": following.used,
                  "following_seconds": following.seconds])
    }

    private static func verifyReplacementReload(
        _ engine: InferenceEngine, wav: Data, fixtureConfig: URL, configText: String, config: AppConfig
    ) async throws {
        defer { try? configText.write(to: fixtureConfig, atomically: true, encoding: .utf8) }
        let initial = try await engine.recognize(wav: wav)
        guard !initial.raw.isEmpty else { throw VerificationFailure("Replacement-reload fixture produced no text") }
        let marker = "DICTATE_REPLACEMENT_RELOAD_VERIFIED"
        let pairs = [Replacement(source: initial.raw, replacement: marker)]
        try replacingPairs(in: configText, with: pairs)
            .write(to: fixtureConfig, atomically: true, encoding: .utf8)
        let reloaded = try await engine.recognize(wav: wav)
        guard reloaded.replaced == marker else {
            throw VerificationFailure("Replacement edit did not apply to the next utterance")
        }
        try "[speech\ninvalid configuration".write(to: fixtureConfig, atomically: true, encoding: .utf8)
        let retained = try await engine.recognize(wav: wav)
        guard retained.replaced == marker else {
            throw VerificationFailure("Invalid config discarded the last-good replacements")
        }
        try configText.write(to: fixtureConfig, atomically: true, encoding: .utf8)
        let restored = try await engine.recognize(wav: wav)
        guard restored.replaced == CleanupRules.replacements(restored.raw, pairs: config.replacements) else {
            throw VerificationFailure("Restoring the config did not restore its replacement rules")
        }
        try emit(["event": "replacement_reload", "raw": initial.raw, "marker": marker,
                  "replacement_applied": true, "invalid_config_retained_last_good": true,
                  "original_config_restored": true, "restored_text": restored.replaced])
    }

    private static func emit(_ row: [String: Any]) throws {
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func replacingPairs(in original: String, with pairs: [Replacement]) throws -> String {
        var skipping = false
        var lines: [String] = []
        for line in original.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                skipping = trimmed.components(separatedBy: "#").first?
                    .trimmingCharacters(in: .whitespaces) == "[replacements]"
            }
            if !skipping { lines.append(line) }
        }
        lines.append("[replacements]")
        for pair in pairs {
            lines.append("\(try quoted(pair.source)) = \(try quoted(pair.replacement))")
        }
        let text = lines.joined(separator: "\n") + "\n"
        _ = try ConfigFile.parse(text)
        return text
    }

    private static func quoted(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value,
                                              options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}

private struct Fixtures: Decodable { let cases: [Fixture] }
private struct Fixture: Decodable { let id: String; let source: String; let replacements: [[String]] }
private struct VerificationFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
