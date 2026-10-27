import Foundation

/// One hold of the talk key, written as the steps happen.
struct DebugTrail {
    let directory: URL
    let stamp: String

    static func begin() throws -> DebugTrail {
        let stamp = Self.stamp()
        let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Logs/Dictate/debug", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return DebugTrail(directory: root, stamp: stamp)
    }

    func write(name: String, data: Data) throws {
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    func write(name: String, text: String) throws {
        try write(name: name, data: Data(text.utf8))
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date()) + "-" + UUID().uuidString
    }
}
