import Foundation

/// The arithmetic for turning other audio down while recording, so the
/// microphone does not pick up music. The volume calls live in the app.
public enum Duck {
    /// Recording plays other audio at a tenth of its volume.
    public static let factor: Float = 0.1

    public static func level(from volume: Float) -> Float {
        volume * factor
    }

    /// Put the volume back only if it is still where Dictate left it. A
    /// different value means the user moved it while recording, and theirs wins.
    public static func shouldRestore(current: Float, ducked: Float) -> Bool {
        abs(current - ducked) < 0.01
    }
}
