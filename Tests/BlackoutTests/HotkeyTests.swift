import Testing
import BlackoutCore

struct HotkeyTests {

    @Test func defaultIsTheOriginalShortcut() {
        #expect(Hotkey.default.keyCode == 0x2A)
        #expect(Hotkey.default.modifiers == Hotkey.control | Hotkey.option | Hotkey.command)
        #expect(Hotkey.default.display == "⌃⌥⌘\\")
    }

    /// Modifiers always print in the order macOS uses in its own menus
    @Test func displayOrdersModifiersLikeMacOS() {
        let all = Hotkey(keyCode: 11, modifiers: Hotkey.command | Hotkey.shift | Hotkey.option | Hotkey.control, keyLabel: "B")
        #expect(all.display == "⌃⌥⇧⌘B")
        #expect(Hotkey(keyCode: 96, modifiers: Hotkey.command, keyLabel: "F5").display == "⌘F5")
    }

    /// A shortcut without ⌘, ⌃ or ⌥ would swallow ordinary typing: a bare
    /// "B", or Shift-B, can never be typed again anywhere
    @Test func needsARealModifier() {
        #expect(Hotkey.problem(keyCode: 11, modifiers: 0) != nil)
        #expect(Hotkey.problem(keyCode: 11, modifiers: Hotkey.shift) != nil)
        #expect(Hotkey.problem(keyCode: 11, modifiers: Hotkey.command) == nil)
        #expect(Hotkey.problem(keyCode: 11, modifiers: Hotkey.control | Hotkey.shift) == nil)
        #expect(Hotkey.problem(keyCode: 11, modifiers: Hotkey.option) == nil)
    }

    @Test func labelsNameTheKeysThatHaveNoCharacter() {
        #expect(Hotkey.label(forKeyCode: 49, characters: " ") == "Space")
        #expect(Hotkey.label(forKeyCode: 36, characters: "\r") == "Return")
        #expect(Hotkey.label(forKeyCode: 96, characters: nil) == "F5")
        #expect(Hotkey.label(forKeyCode: 123, characters: nil) == "←")
        #expect(Hotkey.label(forKeyCode: 11, characters: "b") == "B")
        #expect(Hotkey.label(forKeyCode: 0x2A, characters: "\\") == "\\")
        // A key that yields nothing printable still gets a name
        #expect(Hotkey.label(forKeyCode: 200, characters: nil) == "Key 200")
        #expect(Hotkey.label(forKeyCode: 200, characters: "") == "Key 200")
    }

    @Test func modifierMaskFromFlags() {
        #expect(Hotkey.modifiers(command: true, option: false, control: true, shift: false) == Hotkey.command | Hotkey.control)
        #expect(Hotkey.modifiers(command: false, option: false, control: false, shift: false) == 0)
        #expect(Hotkey.modifiers(command: true, option: true, control: true, shift: true) == Hotkey.command | Hotkey.option | Hotkey.control | Hotkey.shift)
    }
}
