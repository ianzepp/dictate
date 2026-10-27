extension Recorder {
    static func checkBuffers() throws -> Bool {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 2, interleaved: true)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        input.frameLength = 4
        let samples: [Int16] = [1, 2, 3, 4, 5, 6, 7, 8]
        for index in samples.indices { input.int16ChannelData![0][index] = samples[index] }
        guard let cloned = copy(input), cloned.frameLength == 4,
            Array(UnsafeBufferPointer(start: cloned.int16ChannelData![0], count: 8)) == samples
        else { return false }

        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let clipping = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 3)!
        clipping.frameLength = 3
        for (index, value) in [Float(-2), 0, 2].enumerated() { clipping.floatChannelData![0][index] = value }
        guard try samples16kMono([clipping]) == [-32767, 0, 32767],
            try samples16kMono([]).isEmpty
        else { return false }

        let stereo = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        var chunks: [AVAudioPCMBuffer] = []
        for _ in 0..<10 {
            let chunk = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 480)!
            chunk.frameLength = 480
            for channel in 0..<2 {
                for frame in 0..<480 { chunk.floatChannelData![channel][frame] = 0.25 }
            }
            guard let cloned = copy(chunk), cloned.floatChannelData![1][479] == 0.25 else { return false }
            chunks.append(chunk)
        }
        let converted = try samples16kMono(chunks)
        return abs(converted.count - 1600) <= 1 && converted.contains { $0 != 0 }
    }
}

@main
struct RecorderChecks {
    static func main() throws {
        guard try Recorder.checkBuffers() else {
            FileHandle.standardError.write(Data("Audio copy or conversion lost samples\n".utf8))
            Foundation.exit(1)
        }
        print("Audio layout, clipping and resampling checks passed without opening a microphone")
    }
}
