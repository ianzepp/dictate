extension VolumeDucker {
    static func checkRecoveryEntries() -> Bool {
        var session = Session(device: 0, uid: "fixture-device", original: 0.8, lastSet: 0.8)
        for level: Float in [0.8, 0.5, 0.2, 0, 0.3, 0.8] {
            session.lastSet = level
            guard let entry = recoveryEntry(session),
                entry["uid"] as? String == "fixture-device",
                entry["volume"] as? Float == 0.8,
                entry["ducked"] as? Float == level
            else { return false }
        }
        return recoveryEntry(Session(device: 0, uid: nil, original: 0.8, lastSet: 0)) == nil
    }
}

@main
struct VolumeDuckerChecks {
    static func main() {
        guard VolumeDucker.checkRecoveryEntries() else {
            FileHandle.standardError.write(Data("Crash recovery did not track the current fade level\n".utf8))
            Foundation.exit(1)
        }
        print("Fade recovery snapshots passed without changing system volume or preferences")
    }
}
