extension DebugTrail {
    static func checkUniqueStamps() -> Bool {
        let stamps = (0..<128).map { _ in stamp() }
        return Set(stamps).count == stamps.count && stamps.allSatisfy { !$0.contains("/") }
    }
}

@main
struct DebugTrailChecks {
    static func main() {
        guard DebugTrail.checkUniqueStamps() else {
            FileHandle.standardError.write(Data("Debug sessions shared a directory name\n".utf8))
            Foundation.exit(1)
        }
        print("Debug trail uniqueness passed without writing any log files")
    }
}
