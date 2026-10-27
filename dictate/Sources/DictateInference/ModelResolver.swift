import Foundation
import HuggingFace

enum InferenceFailure: Error, LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}

struct ModelResolver {
    let root: URL

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/dictate/models", isDirectory: true)) {
        self.root = root
    }

    func directory(for model: String) -> URL {
        if model.hasPrefix("/") || model.hasPrefix("~") || model.hasPrefix(".") {
            return URL(fileURLWithPath: NSString(string: model).expandingTildeInPath,
                       isDirectory: true)
        }
        return root.appendingPathComponent(model.replacingOccurrences(of: "/", with: "--"),
                                           isDirectory: true)
    }

    func requiresDownload(_ model: String) -> Bool {
        if model.hasPrefix("/") || model.hasPrefix("~") || model.hasPrefix(".") { return false }
        let path = directory(for: model)
        return (try? Self.validate(path)) == nil
    }

    func resolve(_ model: String) async throws -> URL {
        let target = directory(for: model)
        if !requiresDownload(model) {
            try Self.validate(target)
            return target
        }
        guard let repo = Repo.ID(rawValue: model) else {
            throw InferenceFailure.unavailable("Invalid Hugging Face model name: \(model)")
        }
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        // Resuming uses the staging directory. An interrupted download never
        // becomes the model's final path, even if config.json arrived first.
        let staging = root.appendingPathComponent(".\(target.lastPathComponent).incomplete",
                                                 isDirectory: true)
        let hub = HubClient()
        _ = try await hub.downloadSnapshot(of: repo, to: staging,
            matching: ["*.json", "*.safetensors", "*.txt", "*.model", "*.tiktoken"])
        let configuration = try JSONSerialization.jsonObject(
            with: Data(contentsOf: staging.appendingPathComponent("config.json"))) as? [String: Any]
        if configuration?["model_type"] as? String == "whisper" || configuration?["n_mels"] != nil {
            // Whisper sizes share tokenizers by vocabulary, not by repository
            // name. English-only and large-v3 checkpoints have different IDs.
            let vocabulary = (configuration?["n_vocab"] ?? configuration?["vocab_size"]) as? Int
            let processor: Repo.ID
            switch vocabulary {
            case 51864: processor = "openai/whisper-medium.en"
            case 51865: processor = "openai/whisper-medium"
            case 51866: processor = "openai/whisper-large-v3"
            default: throw InferenceFailure.unavailable("Unsupported Whisper tokenizer vocabulary")
            }
            for name in ["tokenizer.json", "tokenizer_config.json", "preprocessor_config.json",
                         "generation_config.json", "special_tokens_map.json", "vocab.json", "merges.txt"] {
                let destination = staging.appendingPathComponent(name)
                if !manager.fileExists(atPath: destination.path) {
                    _ = try await hub.downloadFile(at: name, from: processor, to: destination)
                }
            }
        }
        try Task.checkCancellation()
        try Self.validate(staging)
        try Data(model.utf8).write(to: staging.appendingPathComponent(".dictate-complete"), options: .atomic)
        if manager.fileExists(atPath: target.path) {
            // Preserve a previous partial folder for diagnosis; never erase a
            // configured local model or an unrelated user's directory.
            let partial = root.appendingPathComponent(".\(target.lastPathComponent).partial-\(UUID().uuidString)")
            try manager.moveItem(at: target, to: partial)
        }
        try manager.moveItem(at: staging, to: target)
        return target
    }

    /// Validate existing Python downloads too. A config file alone does not
    /// prove the weights, shard set, or tokenizer finished downloading.
    static func validate(_ directory: URL) throws {
        let manager = FileManager.default
        for name in ["config.json", "tokenizer.json", "tokenizer_config.json"] {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  (try? JSONSerialization.jsonObject(with: data)) != nil else {
                throw InferenceFailure.unavailable("Model folder is missing a valid \(name): \(directory.path)")
            }
        }
        let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var weights = files.filter { $0.pathExtension == "safetensors" }
        let index = directory.appendingPathComponent("model.safetensors.index.json")
        if manager.fileExists(atPath: index.path) {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any]
            guard let map = json?["weight_map"] as? [String: String], !map.isEmpty else {
                throw InferenceFailure.unavailable("The model weight index is incomplete")
            }
            let names = Set(map.values)
            guard names.allSatisfy({ !$0.contains("/") && $0.hasSuffix(".safetensors") }) else {
                throw InferenceFailure.unavailable("The model weight index contains invalid shard paths")
            }
            weights = names.sorted().map { directory.appendingPathComponent($0) }
        }
        guard !weights.isEmpty else {
            throw InferenceFailure.unavailable("Model folder has no safetensors weights: \(directory.path)")
        }
        for weight in weights { try validateWeight(weight) }
    }

    private static func validateWeight(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 8) ?? Data()
        guard prefix.count == 8 else { throw incomplete(url) }
        let headerSize = prefix.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        guard headerSize > 0, headerSize <= 100_000_000 else { throw incomplete(url) }
        let header = try handle.read(upToCount: Int(headerSize)) ?? Data()
        guard header.count == headerSize,
              let entries = try JSONSerialization.jsonObject(with: header) as? [String: Any] else {
            throw incomplete(url)
        }
        var end: UInt64 = 0
        var tensors = 0
        for (name, value) in entries where name != "__metadata__" {
            guard let tensor = value as? [String: Any],
                  let offsets = tensor["data_offsets"] as? [NSNumber], offsets.count == 2,
                  offsets[0].int64Value >= 0, offsets[1].int64Value >= offsets[0].int64Value else {
                throw incomplete(url)
            }
            end = max(end, offsets[1].uint64Value)
            tensors += 1
        }
        guard tensors > 0, try handle.seekToEnd() >= 8 + headerSize + end else { throw incomplete(url) }
    }

    private static func incomplete(_ url: URL) -> InferenceFailure {
        .unavailable("Model weights are incomplete: \(url.lastPathComponent)")
    }
}
