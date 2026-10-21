import AVFoundation
import DictateCore
import Foundation

enum RecorderError: LocalizedError {
    case noInput
    case empty
    case convert(String)

    var errorDescription: String? {
        switch self {
        case .noInput: return "No microphone input"
        case .empty: return "Nothing recorded"
        case .convert(let detail): return detail
        }
    }
}

/// One hold of the key: the upload, and whether anyone spoke.
struct Recording {
    let wav: Data
    let hasSpeech: Bool
}

final class Recorder {
    private let engine = AVAudioEngine()
    private var chunks: [AVAudioPCMBuffer] = []
    private let lock = NSLock()
    private(set) var isRecording = false
    /// Microphone level from 0 to 1, delivered on the main queue while recording.
    var onLevel: ((Float) -> Void)?

    func start() throws {
        if isRecording { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }
        lock.lock()
        chunks.removeAll()
        lock.unlock()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let copy = Self.copy(buffer) else { return }
            if let onLevel = self?.onLevel {
                let level = Self.level(copy)
                DispatchQueue.main.async { onLevel(level) }
            }
            self?.lock.lock()
            self?.chunks.append(copy)
            self?.lock.unlock()
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            throw error
        }
        isRecording = true
    }

    func stop() throws -> Recording {
        guard isRecording else { throw RecorderError.empty }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        lock.lock()
        let taken = chunks
        chunks = []
        lock.unlock()
        let samples = try Self.samples16kMono(taken)
        if samples.isEmpty { throw RecorderError.empty }
        return Recording(wav: Wav.pcm16Mono(samples: samples), hasSpeech: Speech.hasSpeech(samples))
    }

    /// RMS of the first channel on a -50 to -10 dBFS scale, so normal speech fills it.
    private static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channel = buffer.floatChannelData?[0] else { return 0 }
        var sum: Float = 0
        for index in 0..<frames {
            sum += channel[index] * channel[index]
        }
        let rms = (sum / Float(frames)).squareRoot()
        let db = 20 * log10(max(rms, 1e-6))
        return max(0, min(1, (db + 50) / 40))
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        guard frames > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for channel in 0..<channels {
                dst[channel].update(from: src[channel], count: frames)
            }
            return copy
        }
        if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for channel in 0..<channels {
                dst[channel].update(from: src[channel], count: frames)
            }
            return copy
        }
        return nil
    }

    private static func samples16kMono(_ buffers: [AVAudioPCMBuffer]) throws -> [Int16] {
        guard let first = buffers.first else { return [] }
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else { throw RecorderError.convert("Could not build 16 kHz format") }
        guard let converter = AVAudioConverter(from: first.format, to: outFormat) else {
            throw RecorderError.convert("Could not convert microphone audio")
        }
        let feed = BufferFeed(buffers)
        var floats: [Float] = []
        floats.reserveCapacity(16000 * 30)
        let chunk = AVAudioFrameCount(4096)
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunk) else { break }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, outStatus in
                feed.next(outStatus)
            }
            if let error { throw RecorderError.convert(error.localizedDescription) }
            if out.frameLength > 0, let channel = out.floatChannelData {
                floats.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
            }
            if status == .endOfStream || status == .error { break }
        }
        return floats.map { sample in
            let clamped = max(-1, min(1, sample))
            return Int16(clamped * 32767)
        }
    }
}

private final class BufferFeed {
    let buffers: [AVAudioPCMBuffer]
    var index = 0
    init(_ buffers: [AVAudioPCMBuffer]) { self.buffers = buffers }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if index >= buffers.count {
            status.pointee = .endOfStream
            return nil
        }
        let buffer = buffers[index]
        index += 1
        status.pointee = .haveData
        return buffer
    }
}
