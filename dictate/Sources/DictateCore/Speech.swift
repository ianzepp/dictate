import Foundation

/// Whisper turns a silent recording into a stock phrase such as "Thank you."
/// instead of nothing, so a hold with no speech in it is dropped before upload.
public enum Speech {
    /// Measured on 407 saved holds: at least 0.15 s of 30 ms frames above
    /// -50 dBFS kept every real utterance and caught 36 of 40 hallucinations.
    public static let thresholdDB: Double = -50
    public static let minimumVoicedSeconds: Double = 0.15

    public static func voicedSeconds(_ samples: [Int16], sampleRate: Int = 16000) -> Double {
        let frame = sampleRate * 30 / 1000
        guard frame > 0, samples.count >= frame else { return 0 }
        let floor = pow(10, thresholdDB / 20) * 32768
        let floorSquared = floor * floor * Double(frame)
        var voiced = 0
        var start = 0
        while start + frame <= samples.count {
            var sum: Double = 0
            for sample in samples[start..<(start + frame)] {
                let value = Double(sample)
                sum += value * value
            }
            if sum > floorSquared { voiced += 1 }
            start += frame
        }
        return Double(voiced * frame) / Double(sampleRate)
    }

    public static func hasSpeech(_ samples: [Int16], sampleRate: Int = 16000) -> Bool {
        voicedSeconds(samples, sampleRate: sampleRate) >= minimumVoicedSeconds
    }
}
