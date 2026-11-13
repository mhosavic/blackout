import Foundation

/// The global shortcut that toggles blackout. Saved with the settings, so
/// each person can pick one that does not collide with their other tools.
public struct Hotkey: Equatable {

    /// The physical key (a macOS virtual key code), so the shortcut keeps
    /// working when the keyboard layout changes
    public var keyCode: UInt32
    /// Carbon modifier mask: any of `command`, `shift`, `option`, `control`
    public var modifiers: UInt32
    /// What the key is called, for display: "\\", "B", "F5", "Space"
    public var keyLabel: String

    public init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    // Carbon's cmdKey, shiftKey, optionKey and controlKey, restated so the
    // library does not have to import Carbon for four constants
    public static let command: UInt32 = 0x0100
    public static let shift: UInt32 = 0x0200
    public static let option: UInt32 = 0x0800
    public static let control: UInt32 = 0x1000

    /// ⌃⌥⌘\ — the shortcut blackout has always had
    public static let `default` = Hotkey(keyCode: 0x2A, modifiers: control | option | command, keyLabel: "\\")

    /// "⌃⌥⌘\", with the modifiers in the order macOS prints them
    public var display: String {
        var symbols = ""
        if modifiers & Hotkey.control != 0 { symbols += "⌃" }
        if modifiers & Hotkey.option != 0 { symbols += "⌥" }
        if modifiers & Hotkey.shift != 0 { symbols += "⇧" }
        if modifiers & Hotkey.command != 0 { symbols += "⌘" }
        return symbols + keyLabel
    }

    /// Why this combination cannot be a global shortcut, or nil if it can.
    /// Without ⌘, ⌃ or ⌥ it would swallow ordinary typing everywhere.
    public static func problem(keyCode: UInt32, modifiers: UInt32) -> String? {
        guard modifiers & (command | control | option) != 0 else {
            return "Add ⌘, ⌃ or ⌥ to the shortcut"
        }
        return nil
    }

    public static func modifiers(command: Bool, option: Bool, control: Bool, shift: Bool) -> UInt32 {
        var mask: UInt32 = 0
        if command { mask |= Hotkey.command }
        if option { mask |= Hotkey.option }
        if control { mask |= Hotkey.control }
        if shift { mask |= Hotkey.shift }
        return mask
    }

    /// Keys that type nothing printable, by virtual key code
    private static let namedKeys: [UInt32: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc", 117: "Forward Delete",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]

    /// The display name of a key: its own name if it has one, else the
    /// character it types without modifiers, upper-cased
    public static func label(forKeyCode keyCode: UInt32, characters: String?) -> String {
        if let name = namedKeys[keyCode] { return name }
        if let characters, !characters.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return characters.uppercased()
        }
        return "Key \(keyCode)"
    }
}
