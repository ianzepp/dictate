/// Hold-to-talk keys. Codes match HIToolbox Events.h.
///
/// Press and release are a pair of flagsChanged events that share this keyCode.
/// The modifier bit is the one that is set only while this key is down: the
/// device-dependent bit from IOKit's NX_DEVICE* masks for a sided key, and the
/// secondary-Fn bit for Fn. Both NSEvent and CGEventSource flags carry them.
public struct HotkeySpec: Equatable, Sendable {
    public var name: String
    public var keyCode: UInt16
    public var modifierBit: UInt
    /// The side-independent bit (any Option, any Command), for state polls that
    /// may not carry the device bits. Fn has only the one bit.
    public var anySideBit: UInt

    public init(name: String, keyCode: UInt16, modifierBit: UInt, anySideBit: UInt) {
        self.name = name
        self.keyCode = keyCode
        self.modifierBit = modifierBit
        self.anySideBit = anySideBit
    }

    public static func named(_ name: String) -> HotkeySpec? {
        switch name {
        case "fn":
            return HotkeySpec(name: name, keyCode: 0x3F, modifierBit: 1 << 23, anySideBit: 1 << 23)
        case "right_option":
            return HotkeySpec(name: name, keyCode: 0x3D, modifierBit: 0x40, anySideBit: 1 << 19)
        case "left_option":
            return HotkeySpec(name: name, keyCode: 0x3A, modifierBit: 0x20, anySideBit: 1 << 19)
        case "right_command":
            return HotkeySpec(name: name, keyCode: 0x36, modifierBit: 0x10, anySideBit: 1 << 20)
        case "left_command":
            return HotkeySpec(name: name, keyCode: 0x37, modifierBit: 0x08, anySideBit: 1 << 20)
        case "right_control":
            return HotkeySpec(name: name, keyCode: 0x3E, modifierBit: 0x2000, anySideBit: 1 << 18)
        case "right_shift":
            return HotkeySpec(name: name, keyCode: 0x3C, modifierBit: 0x04, anySideBit: 1 << 17)
        default:
            return nil
        }
    }
}

public enum HoldEdge: Equatable {
    case pressed
    case released
}

public struct HoldTracker {
    public private(set) var holding = false

    public init() {}

    /// Reads whether the key is down from the event's flags rather than counting
    /// events, so a missed press or release corrects itself on the next one.
    public mutating func handle(keyCode: UInt16, flags: UInt, spec: HotkeySpec) -> HoldEdge? {
        guard keyCode == spec.keyCode else { return nil }
        return update(down: flags & spec.modifierBit != 0)
    }

    /// For a poll of the live keyboard state: reports only a release.
    public mutating func check(flags: UInt, spec: HotkeySpec) -> HoldEdge? {
        guard holding, flags & spec.anySideBit == 0 else { return nil }
        return update(down: false)
    }

    public mutating func reset() {
        holding = false
    }

    private mutating func update(down: Bool) -> HoldEdge? {
        guard down != holding else { return nil }
        holding = down
        return down ? .pressed : .released
    }
}
