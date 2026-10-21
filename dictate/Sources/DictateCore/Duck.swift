import Foundation

/// The arithmetic for turning other audio down while recording, so the
/// microphone does not pick up music. The volume calls live in the app.
public enum Duck {
    /// Recording silences other audio. A tenth of the volume was tried first:
    /// on laptop speakers Whisper still transcribed the lyrics, and a stricter
    /// silence check would have dropped quiet speech.
    public static let factor: Float = 0

    public static func level(from volume: Float) -> Float {
        volume * factor
    }

    /// Seconds to fade down at a press, and back up after. Fading down from the
    /// press means a tap only dips the volume slightly before it comes back.
    public static let fadeDown: Double = 0.15
    public static let fadeUp: Double = 0.25

    /// The volume part way through a fade, clamped to the end points.
    public static func fade(from start: Float, to end: Float, elapsed: Double, duration: Double) -> Float {
        guard duration > 0, elapsed < duration else { return end }
        let progress = Float(max(0, elapsed) / duration)
        return start + (end - start) * progress
    }

    /// Keep fading or restoring only while the volume is where Dictate last set
    /// it. A different value means the user moved it, and theirs wins.
    public static func shouldRestore(current: Float, ducked: Float) -> Bool {
        abs(current - ducked) < 0.01
    }
}
