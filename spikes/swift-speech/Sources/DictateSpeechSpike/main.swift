import Foundation
import MLX
import MLXAudioCore
import MLXAudioSTT

// One process keeps the model loaded, matching the resident Python service.
// Inference is serialized. This CLI has no user interface to block.
@main
struct DictateSpeechSpike {
    @MainActor
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else {
            FileHandle.standardError.write(Data(
                "Usage: DictateSpeechSpike MODEL_DIRECTORY AUDIO.wav [AUDIO.wav ...]\n".utf8))
            Foundation.exit(2)
        }
        do {
            try await run(args)
        } catch {
            FileHandle.standardError.write(Data("Speech spike failed: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func run(_ args: [String]) async throws {
        guard Device.defaultDevice().deviceType == .gpu else {
            throw NSError(domain: "SpeechSpike", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The model loader must use the GPU"])
        }
        let directory = URL(fileURLWithPath: args[0], isDirectory: true)
        let started = ProcessInfo.processInfo.systemUptime
        let model = try await WhisperModel.fromDirectory(directory)
        let loadSeconds = ProcessInfo.processInfo.systemUptime - started
        try Device.withDefaultDevice(.gpu) {
            try transcribe(args, model: model, directory: directory, loadSeconds: loadSeconds)
        }
    }

    private static func transcribe(
        _ args: [String], model: WhisperModel, directory: URL, loadSeconds: Double
    ) throws {
        for filename in args.dropFirst() {
            let (_, audio) = try loadAudioArray(
                from: URL(fileURLWithPath: filename), sampleRate: 16000)
            // First inference is separately reported; the next three are warm.
            for iteration in 0..<4 {
                let began = ProcessInfo.processInfo.systemUptime
                let output = model.generate(
                    audio: audio,
                    generationParameters: STTGenerateParameters(language: "en"))
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                let row: [String: Any] = [
                    "runtime": "swift",
                    "device": String(describing: Device.defaultDevice()),
                    "model_directory": directory.path,
                    "audio": filename,
                    "iteration": iteration,
                    "warmup": iteration == 0,
                    "model_load_seconds": loadSeconds,
                    "wall_seconds": elapsed,
                    "audio_seconds": Double(audio.dim(0)) / 16000,
                    "text": output.text,
                ]
                let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        }
    }
}
