import Foundation
import MLX
import MLXLLM
import MLXLMCommon

@main
struct DictateCleanupSpike {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 2 else {
            FileHandle.standardError.write(Data(
                "Usage: DictateCleanupSpike MODEL_DIRECTORY CLEANUP_PROMPTS.json\n".utf8))
            Foundation.exit(2)
        }
        do {
            try await run(args)
        } catch {
            FileHandle.standardError.write(Data("Cleanup spike failed: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func run(_ args: [String]) async throws {
        guard Device.defaultDevice().deviceType == .gpu else {
            throw failure("The model loader must use the GPU")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let fixtures = try decoder.decode(CleanupFixtures.self,
            from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        guard !fixtures.cases.isEmpty else { throw failure("No cleanup cases") }
        let directory = URL(fileURLWithPath: args[0], isDirectory: true)
        let began = ProcessInfo.processInfo.systemUptime
        let context = try await LLMModelFactory.shared.load(
            from: directory, using: LocalTokenizerLoader())
        let loadSeconds = ProcessInfo.processInfo.systemUptime - began
        var needsWarmup = true
        for testCase in fixtures.cases {
            guard !testCase.chunks.isEmpty else { throw failure("No chunks in \(testCase.id)") }
            for chunk in testCase.chunks {
                let iterations = needsWarmup ? Array(0...3) : Array(1...3)
                needsWarmup = false
                for iteration in iterations {
                    let started = ProcessInfo.processInfo.systemUptime
                    let messages: [[String: any Sendable]] = chunk.messages.map {
                        ["role": $0.role, "content": $0.content]
                    }
                    let promptTokens = try context.tokenizer.applyChatTemplate(messages: messages)
                    guard promptTokens == chunk.promptTokens else {
                        throw failure("Prompt tokens differ from Python: \(testCase.id)/\(chunk.index)")
                    }
                    let input = LMInput(tokens: MLXArray(promptTokens))
                    let stream = try Device.withDefaultDevice(.gpu) {
                        try MLXLMCommon.generate(
                            input: input,
                            parameters: GenerateParameters(maxTokens: 1024, temperature: 0),
                            context: context)
                    }
                    var text = ""
                    var info: GenerateCompletionInfo?
                    for await event in stream {
                        switch event {
                        case .chunk(let value): text += value
                        case .info(let value): info = value
                        case .toolCall, .rejectedToolCall:
                            throw failure("Unexpected tool output in \(testCase.id)")
                        }
                    }
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let info else { throw failure("Incomplete generation in \(testCase.id)") }
                    let elapsed = ProcessInfo.processInfo.systemUptime - started
                    let row: [String: Any] = [
                        "runtime": "swift", "case_id": testCase.id, "chunk_index": chunk.index,
                        "iteration": iteration, "warmup": iteration == 0, "source": chunk.source,
                        "text": text, "wall_seconds": elapsed, "model_load_seconds": loadSeconds,
                        "prompt_tokens": promptTokens, "generated_tokens": info.generationTokenCount,
                        "stop_reason": String(describing: info.stopReason),
                        "device": String(describing: Device.defaultDevice()),
                        "model_directory": directory.path,
                    ]
                    let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write(Data("\n".utf8))
                }
            }
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "CleanupSpike", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private struct CleanupFixtures: Decodable {
    var cases: [CleanupCase]
}

private struct CleanupCase: Decodable {
    var id: String
    var chunks: [CleanupChunk]
}

private struct CleanupChunk: Decodable {
    var index: Int
    var source: String
    var messages: [ChatMessage]
    var promptTokens: [Int]
}

private struct ChatMessage: Decodable {
    var role: String
    var content: String
}
