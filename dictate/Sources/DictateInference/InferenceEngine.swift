import Foundation
import DictateCore
@preconcurrency import MLX
import MLXAudioCore
@preconcurrency import MLXAudioSTT
@preconcurrency import MLXLLM
@preconcurrency import MLXLMCommon

public struct RecognitionResult: Sendable, Codable {
    public let raw: String
    public let replaced: String
    public let seconds: Double
}

public struct CleanupResult: Sendable, Codable {
    public let text: String
    public let used: Bool
    public let seconds: Double
}

/// Models never leave this actor. The additional gate keeps their exclusive
/// ownership across actor suspension points in the SDK's loaders/generator.
/// MLX's task-local GPU streams follow the job across Swift executor threads.
public actor InferenceEngine {
    private let config: AppConfig
    private let configURL: URL
    private let resolver = ModelResolver()
    private let gate = SerialGate()
    private var replacements: [Replacement]
    private var speech: WhisperModel?
    private var cleanupModel: ModelContext?
    private var preparing = false
    private var speechStatus = ModelStatus(state: .loading, detail: "Preparing the speech model")
    private var cleanupStatus: ModelStatus

    public init(config: AppConfig, configURL: URL) {
        self.config = config
        self.configURL = configURL
        self.replacements = config.replacements
        self.cleanupStatus = config.cleanupEnabled
            ? ModelStatus(state: .loading, detail: "Preparing cleanup")
            : ModelStatus(state: .off, detail: "Turned off in the config")
    }

    public func status() -> InferenceStatus {
        InferenceStatus(speech: speechStatus, cleanup: cleanupStatus)
    }

    /// One attempt; the app retries after 30 seconds if a model is unavailable.
    /// Downloads and retry delays do not reserve the inference gate, so speech
    /// remains usable while cleanup is downloading or unavailable.
    public func prepare() async {
        guard !preparing else { return }
        preparing = true
        defer { preparing = false }
        if speech == nil {
            do {
                try Task.checkCancellation()
                speechStatus = ModelStatus(state: resolver.requiresDownload(config.speechModel) ? .downloading : .loading,
                                           detail: "Preparing \(config.speechModel)")
                let directory = try await resolver.resolve(config.speechModel)
                speechStatus = ModelStatus(state: .loading, detail: "Loading the speech model")
                try await exclusively {
                    try Task.checkCancellation()
                    try self.requireGPU()
                    let loaded = try await Stream.withNewDefaultStream(device: .gpu) {
                        try await WhisperModel.fromDirectory(directory)
                    }
                    try Task.checkCancellation()
                    self.speech = loaded
                }
                speechStatus = ModelStatus(state: .ready, detail: "")
            } catch is CancellationError { return }
            catch { speechStatus = ModelStatus(state: .failed, detail: failureDetail(error)) }
        }
        guard config.cleanupEnabled else { return }
        if config.cleanupModel.isEmpty {
            await checkExternalCleanup()
        } else if cleanupModel == nil {
            do {
                try Task.checkCancellation()
                cleanupStatus = ModelStatus(state: resolver.requiresDownload(config.cleanupModel) ? .downloading : .loading,
                                            detail: "Preparing \(config.cleanupModel)")
                let directory = try await resolver.resolve(config.cleanupModel)
                cleanupStatus = ModelStatus(state: .loading, detail: "Loading cleanup")
                try await exclusively {
                    try Task.checkCancellation()
                    try self.requireGPU()
                    let loaded = try await Stream.withNewDefaultStream(device: .gpu) {
                        try await LLMModelFactory.shared.load(from: directory, using: LocalTokenizerLoader())
                    }
                    try Task.checkCancellation()
                    self.cleanupModel = loaded
                }
                cleanupStatus = ModelStatus(state: .ready, detail: "")
            } catch is CancellationError { return }
            catch { cleanupStatus = ModelStatus(state: .failed, detail: failureDetail(error)) }
        }
    }

    public func recognize(wav: Data) async throws -> RecognitionResult {
        try Task.checkCancellation()
        reloadReplacements()
        let pairs = replacements
        return try await exclusively {
            try Task.checkCancellation()
            guard let model = self.speech else {
                throw InferenceFailure.unavailable("The speech model is unavailable: \(self.speechStatus.detail)")
            }
            let began = ProcessInfo.processInfo.systemUptime
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-\(UUID().uuidString).wav")
            try wav.write(to: path, options: .atomic)
            defer { try? FileManager.default.removeItem(at: path) }
            let raw = try Stream.withNewDefaultStream(device: .gpu) {
                let (_, audio) = try loadAudioArray(from: path, sampleRate: 16000)
                try Task.checkCancellation()
                let output = model.generate(audio: audio,
                    generationParameters: STTGenerateParameters(language: self.config.speechLanguage))
                Stream.defaultStream.synchronize()
                return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // Whisper exposes synchronous generation, so cancellation cannot
            // interrupt its current kernel. It always discards the completion.
            try Task.checkCancellation()
            return RecognitionResult(raw: raw, replaced: CleanupRules.replacements(raw, pairs: pairs),
                                     seconds: ProcessInfo.processInfo.systemUptime - began)
        }
    }

    public func cleanup(text: String) async throws -> CleanupResult {
        try Task.checkCancellation()
        reloadReplacements()
        let pairs = replacements
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CleanupResult(text: "", used: false, seconds: 0)
        }
        guard config.cleanupEnabled else { return CleanupResult(text: text, used: false, seconds: 0) }
        let began = ProcessInfo.processInfo.systemUptime
        var results: [String] = []
        var used = false
        for chunk in CleanupRules.chunks(text) {
            try Task.checkCancellation()
            let messages = CleanupRules.messages(chunk, pairs: pairs)
            var response: String?
            do {
                if config.cleanupModel.isEmpty {
                    response = try await externalCompletion(messages)
                    cleanupStatus = ModelStatus(state: .ready, detail: "")
                } else {
                    response = try await exclusively {
                        try Task.checkCancellation()
                        guard let context = self.cleanupModel else { return nil }
                        return try await self.localCompletion(messages, context: context)
                    }
                }
            } catch {
                // Cancellation is control flow, never a successful literal
                // fallback. URLSession cancellation can also be URLError.
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                if self.config.cleanupModel.isEmpty {
                    cleanupStatus = ModelStatus(state: .unreachable, detail: failureDetail(error))
                }
                response = nil
            }
            try Task.checkCancellation()
            if let accepted = CleanupRules.accepted(chunk, response: response) {
                results.append(accepted)
                used = true
            } else { results.append(chunk) }
        }
        try Task.checkCancellation()
        return CleanupResult(text: results.joined(separator: " "), used: used,
                             seconds: ProcessInfo.processInfo.systemUptime - began)
    }

    private func localCompletion(_ messages: [CleanupMessage], context: ModelContext) async throws -> String {
        try await Stream.withNewDefaultStream(device: .gpu) {
            let chat: [[String: any Sendable]] = messages.map { ["role": $0.role, "content": $0.content] }
            let tokens = try context.tokenizer.applyChatTemplate(messages: chat)
            let iterator = try TokenIterator(input: LMInput(tokens: MLXArray(tokens)), model: context.model,
                                             parameters: GenerateParameters(maxTokens: 1024, temperature: 0))
            let (stream, producer) = MLXLMCommon.generateTask(promptTokenCount: tokens.count,
                modelConfiguration: context.configuration, tokenizer: context.tokenizer, iterator: iterator)
            // Awaiting producer termination is required before the model can
            // be touched again, even when stream consumption was canceled.
            return try await withTaskCancellationHandler {
                var output = ""
                var completed = false
                do {
                    for await event in stream {
                        try Task.checkCancellation()
                        switch event {
                        case .chunk(let chunk): output += chunk
                        case .info: completed = true
                        case .toolCall, .rejectedToolCall:
                            throw InferenceFailure.unavailable("Cleanup returned a tool call")
                        }
                    }
                    await producer.value
                    try Task.checkCancellation()
                    guard completed else { throw InferenceFailure.unavailable("Cleanup generation did not finish") }
                    return output
                } catch {
                    producer.cancel()
                    await producer.value
                    throw error
                }
            } onCancel: { producer.cancel() }
        }
    }

    private func externalCompletion(_ messages: [CleanupMessage]) async throws -> String? {
        guard let endpoint = URL(string: config.cleanupURL + "/chat/completions") else {
            throw InferenceFailure.unavailable("Invalid cleanup URL")
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": config.cleanupName,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "max_tokens": 1024, "temperature": 0.0]
        if !config.cleanupReasoningEffort.isEmpty { body["reasoning_effort"] = config.cleanupReasoningEffort }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw InferenceFailure.unavailable("The cleanup server did not accept the request")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        return message?["content"] as? String
    }

    private func checkExternalCleanup() async {
        guard let url = URL(string: config.cleanupURL + "/models") else { return }
        do {
            let (_, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 0.5))
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw InferenceFailure.unavailable("The cleanup server did not answer")
            }
            cleanupStatus = ModelStatus(state: .ready, detail: "")
        } catch {
            if !Task.isCancelled {
                cleanupStatus = ModelStatus(state: .unreachable, detail: "Nothing is answering at \(config.cleanupURL)")
            }
        }
    }

    private func reloadReplacements() {
        // Models and hotkeys remain the launch configuration. Only complete,
        // valid replacement edits take effect without restarting the app.
        if let text = try? String(contentsOf: configURL, encoding: .utf8),
           let next = try? ConfigFile.parse(text) { replacements = next.replacements }
    }

    private func requireGPU() throws {
        guard Device.defaultDevice().deviceType == .gpu else {
            throw InferenceFailure.unavailable("Native inference requires the Metal GPU")
        }
    }

    private func exclusively<T>(_ operation: () async throws -> T) async throws -> T {
        try await gate.acquire()
        do {
            let result = try await operation()
            await gate.release()
            return result
        } catch {
            await gate.release()
            throw error
        }
    }

    private func failureDetail(_ error: Error) -> String {
        let line = error.localizedDescription.split(separator: "\n").first.map(String.init) ?? "Model unavailable"
        return String(line.prefix(180))
    }
}
