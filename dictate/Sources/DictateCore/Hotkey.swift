/// Hold-to-talk keys. Codes match HIToolbox Events.h. Flag bits match NSEvent.ModifierFlags.
///
/// Press and release are a pair of flagsChanged events that share this keyCode.
/// The modifier bit is shared by the other side of the key (and, for Fn, by
/// function keys), so the tracker toggles on the key code instead of the bit.
public struct HotkeySpec: Equatable {
    public var name: String
    public var keyCode: UInt16
    public var modifierBit: UInt

    public init(name: String, keyCode: UInt16, modifierBit: UInt) {
        self.name = name
        self.keyCode = keyCode
        self.modifierBit = modifierBit
    }

    public static func named(_ name: String) -> HotkeySpec? {
        switch name {
        case "fn":
            return HotkeySpec(name: name, keyCode: 0x3F, modifierBit: 1 << 23)
        case "right_option":
            return HotkeySpec(name: name, keyCode: 0x3D, modifierBit: 1 << 19)
        case "left_option":
            return HotkeySpec(name: name, keyCode: 0x3A, modifierBit: 1 << 19)
        case "right_command":
            return HotkeySpec(name: name, keyCode: 0x36, modifierBit: 1 << 20)
        case "left_command":
            return HotkeySpec(name: name, keyCode: 0x37, modifierBit: 1 << 20)
        case "right_control":
            return HotkeySpec(name: name, keyCode: 0x3E, modifierBit: 1 << 18)
        case "right_shift":
            return HotkeySpec(name: name, keyCode: 0x3C, modifierBit: 1 << 17)
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

    public mutating func handle(keyCode: UInt16, spec: HotkeySpec) -> HoldEdge? {
        guard keyCode == spec.keyCode else { return nil }
        holding.toggle()
        return holding ? .pressed : .released
    }
}
