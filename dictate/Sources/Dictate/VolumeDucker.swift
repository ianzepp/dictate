import AudioToolbox
import CoreAudio
import DictateCore
import Foundation

/// Turns the default output down while recording and back up after.
///
/// The original volume is also saved to user defaults, so a crash in the
/// middle of a dictation is repaired on the next launch instead of leaving
/// the Mac at a tenth of its volume. Outputs without a software volume, such
/// as some HDMI and USB devices, are left alone.
final class VolumeDucker {
    private struct Session {
        let device: AudioObjectID
        /// The user's volume before the first press.
        let original: Float32
        /// What Dictate last set, read back from the device.
        var lastSet: Float32
    }

    private static let defaultsKey = "duckedOutput"
    private var session: Session?
    private var timer: Timer?

    init() {
        recoverAfterCrash()
    }

    /// Fades down from the press. A press during a fade back up turns down
    /// again from wherever the volume is, and keeps the original level.
    func duck() {
        if session == nil {
            guard let device = Self.defaultOutput(),
                  Self.isSettable(device),
                  let volume = Self.volume(device), volume > 0.001
            else { return }
            session = Session(device: device, original: volume, lastSet: volume)
            if let uid = Self.uid(device) {
                UserDefaults.standard.set(
                    ["uid": uid, "volume": volume, "ducked": Duck.level(from: volume)],
                    forKey: Self.defaultsKey
                )
            }
        }
        guard let session else { return }
        fade(to: Duck.level(from: session.original), over: Duck.fadeDown) {}
    }

    /// Fades back up to the original volume, unless the user changed it meanwhile.
    func restore() {
        guard let session else { return }
        fade(to: session.original, over: Duck.fadeUp) { [weak self] in
            self?.finish()
        }
    }

    /// No fade: the app is quitting and a timer would not get to run.
    func restoreNow() {
        timer?.invalidate()
        timer = nil
        guard let session else { return }
        if let now = Self.volume(session.device), Duck.shouldRestore(current: now, ducked: session.lastSet) {
            _ = Self.setVolume(session.device, session.original)
        }
        finish()
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        session = nil
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    private func fade(to target: Float32, over duration: Double, then done: @escaping () -> Void) {
        timer?.invalidate()
        guard let start = session?.lastSet else { return }
        let began = Date()
        let timer = Timer(timeInterval: 0.015, repeats: true) { [weak self] timer in
            guard let self, var session = self.session else {
                timer.invalidate()
                return
            }
            guard let now = Self.volume(session.device), Duck.shouldRestore(current: now, ducked: session.lastSet) else {
                // The user moved the volume; leave it where they put it.
                self.finish()
                return
            }
            let elapsed = Date().timeIntervalSince(began)
            let value = Duck.fade(from: start, to: target, elapsed: elapsed, duration: duration)
            if Self.setVolume(session.device, value), let readBack = Self.volume(session.device) {
                session.lastSet = readBack
                self.session = session
            }
            if elapsed >= duration {
                timer.invalidate()
                if self.timer === timer { self.timer = nil }
                done()
            }
        }
        // .common keeps the fade running while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        timer.fire()
    }

    private func recoverAfterCrash() {
        guard let entry = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) else { return }
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        guard let uid = entry["uid"] as? String,
              let volume = (entry["volume"] as? NSNumber)?.floatValue,
              let ducked = (entry["ducked"] as? NSNumber)?.floatValue,
              let device = Self.defaultOutput(), Self.uid(device) == uid,
              let now = Self.volume(device), Duck.shouldRestore(current: now, ducked: ducked)
        else { return }
        _ = Self.setVolume(device, volume)
    }

    // MARK: Core Audio

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static func defaultOutput() -> AudioObjectID? {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func uid(_ device: AudioObjectID) -> String? {
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    private static func isSettable(_ device: AudioObjectID) -> Bool {
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &volumeAddress, &settable) == noErr && settable.boolValue
    }

    private static func volume(_ device: AudioObjectID) -> Float32? {
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &volume) == noErr else { return nil }
        return volume
    }

    private static func setVolume(_ device: AudioObjectID, _ volume: Float32) -> Bool {
        var value = volume
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, size, &value) == noErr
    }
}
