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
    private struct Ducked {
        let device: AudioObjectID
        let volume: Float32
        let ducked: Float32
    }

    private static let defaultsKey = "duckedOutput"
    private var current: Ducked?

    init() {
        recoverAfterCrash()
    }

    func duck() {
        guard current == nil,
              let device = Self.defaultOutput(),
              Self.isSettable(device),
              let volume = Self.volume(device), volume > 0.001,
              Self.setVolume(device, Duck.level(from: volume)),
              let ducked = Self.volume(device)
        else { return }
        current = Ducked(device: device, volume: volume, ducked: ducked)
        if let uid = Self.uid(device) {
            UserDefaults.standard.set(["uid": uid, "volume": volume, "ducked": ducked], forKey: Self.defaultsKey)
        }
    }

    func restore() {
        guard let saved = current else { return }
        current = nil
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        guard let now = Self.volume(saved.device), Duck.shouldRestore(current: now, ducked: saved.ducked) else { return }
        _ = Self.setVolume(saved.device, saved.volume)
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
