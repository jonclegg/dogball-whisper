import CoreGraphics
import Foundation

/// Virtual key codes for the modifier keys we can bind. flagsChanged events
/// carry the code of the physical key that changed, which is the only way to
/// tell left from right (the flag masks themselves are side-agnostic).
enum ModifierKeyCode {
    static let rightCommand: UInt16 = 54
    static let leftCommand: UInt16 = 55
    static let leftShift: UInt16 = 56
    static let leftOption: UInt16 = 58
    static let rightOption: UInt16 = 61
    static let rightShift: UInt16 = 60
    static let leftControl: UInt16 = 59
    static let rightControl: UInt16 = 62
    static let fn: UInt16 = 63

    /// The device-independent flag that appears when this key goes down.
    static func mask(for keyCode: UInt16) -> CGEventFlags? {
        switch keyCode {
        case rightCommand, leftCommand: return .maskCommand
        case leftShift, rightShift: return .maskShift
        case leftOption, rightOption: return .maskAlternate
        case leftControl, rightControl: return .maskControl
        case fn: return .maskSecondaryFn
        default: return nil
        }
    }
}

/// Hashable because SwiftUI's hotkey Picker tags rows with binding values.
struct HotkeyBinding: Codable, Equatable, Hashable {
    enum Kind: String, Codable {
        case modifierOnly
        case combo
    }

    let kind: Kind
    let keyCode: UInt16
    /// Raw CGEventFlags bits. Empty for modifier-only bindings.
    let modifierBits: UInt64

    var modifiers: CGEventFlags { CGEventFlags(rawValue: modifierBits) }
    var isModifierOnly: Bool { kind == .modifierOnly }

    static let rightOption = HotkeyBinding(
        kind: .modifierOnly, keyCode: ModifierKeyCode.rightOption, modifierBits: 0)
    static let rightCommand = HotkeyBinding(
        kind: .modifierOnly, keyCode: ModifierKeyCode.rightCommand, modifierBits: 0)
    static let fn = HotkeyBinding(
        kind: .modifierOnly, keyCode: ModifierKeyCode.fn, modifierBits: 0)

    init(kind: Kind, keyCode: UInt16, modifierBits: UInt64) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifierBits = modifierBits
    }

    init(comboKeyCode: UInt16, modifiers: CGEventFlags) {
        self.init(kind: .combo, keyCode: comboKeyCode, modifierBits: modifiers.rawValue)
    }

    var displayName: String {
        switch kind {
        case .modifierOnly:
            switch keyCode {
            case ModifierKeyCode.rightOption: return "Right ⌥"
            case ModifierKeyCode.rightCommand: return "Right ⌘"
            case ModifierKeyCode.fn: return "fn"
            default: return "Key \(keyCode)"
            }
        case .combo:
            var name = ""
            if modifiers.contains(.maskControl) { name += "⌃" }
            if modifiers.contains(.maskAlternate) { name += "⌥" }
            if modifiers.contains(.maskShift) { name += "⇧" }
            if modifiers.contains(.maskCommand) { name += "⌘" }
            return name + KeyCodeNames.name(for: keyCode)
        }
    }
}

enum KeyCodeNames {
    private static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        36: "Return", 48: "Tab", 49: "Space", 53: "Escape",
    ]

    static func name(for keyCode: UInt16) -> String {
        names[keyCode] ?? "Key \(keyCode)"
    }
}
