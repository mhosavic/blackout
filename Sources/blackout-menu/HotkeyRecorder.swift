import AppKit
import BlackoutCore

/// The small window where the user presses the shortcut they want. While
/// it is open the live shortcut is switched off, so pressing the current
/// one records it instead of toggling blackout.
final class HotkeyRecorder: NSObject, NSWindowDelegate {

    private let hotkeyManager: HotkeyManager
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")

    private static let hint = "Hold ⌘, ⌃ or ⌥ and press a key. Esc cancels."

    /// The live shortcut is off while the window is open, so a window
    /// opened and forgotten must not leave blackout without one
    private static let idleLimit: TimeInterval = 30
    private var idleTimer: Timer?

    init(hotkeyManager: HotkeyManager) {
        self.hotkeyManager = hotkeyManager
    }

    var isRecording: Bool { panel != nil }

    func show() {
        if let panel {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        panel.title = "Blackout Hotkey"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.delegate = self

        let title = NSTextField(labelWithString: "Press the new shortcut")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        shortcutLabel.stringValue = Settings.load().hotkey.display
        shortcutLabel.font = .monospacedSystemFont(ofSize: 30, weight: .medium)
        shortcutLabel.alignment = .center

        hintLabel.stringValue = HotkeyRecorder.hint
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center

        let useDefault = NSButton(title: "Use Default (\(Hotkey.default.display))", target: self, action: #selector(useDefault))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        let buttons = NSStackView(views: [useDefault, cancel])
        buttons.spacing = 12

        let stack = NSStackView(views: [title, shortcutLabel, hintLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        panel.contentView = stack

        self.panel = panel
        hotkeyManager.unregisterHotkey()

        // A local monitor sees every key press while this app is active,
        // including ⌘ combinations that would otherwise go looking for a
        // menu item. Returning nil swallows the press.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil
        }

        // The app has no Dock icon and is never frontmost on its own
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        restartIdleTimer()
        Logger.info("Hotkey recorder opened")
    }

    private func restartIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: HotkeyRecorder.idleLimit, repeats: false) { [weak self] _ in
            Logger.info("Hotkey recorder closed after \(Int(HotkeyRecorder.idleLimit))s without a shortcut")
            self?.close()
        }
    }

    private func handle(_ event: NSEvent) {
        restartIdleTimer()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let modifiers = Hotkey.modifiers(
            command: flags.contains(.command),
            option: flags.contains(.option),
            control: flags.contains(.control),
            shift: flags.contains(.shift))
        let keyCode = UInt32(event.keyCode)

        if keyCode == 53 && modifiers == 0 {
            cancel()
            return
        }

        let candidate = Hotkey(
            keyCode: keyCode,
            modifiers: modifiers,
            // The character the key types with no modifiers held, so ⌥B is
            // labelled "B" and not "∫"
            keyLabel: Hotkey.label(forKeyCode: keyCode, characters: event.characters(byApplyingModifiers: [])))
        shortcutLabel.stringValue = candidate.display

        if let problem = Hotkey.problem(keyCode: keyCode, modifiers: modifiers) {
            showProblem(problem)
            return
        }
        apply(candidate)
    }

    private func apply(_ hotkey: Hotkey) {
        guard hotkeyManager.register(hotkey) else {
            showProblem("macOS did not accept \(hotkey.display). Try another.")
            return
        }
        var settings = Settings.load()
        settings.hotkey = hotkey
        if !settings.save() {
            Logger.error("Could not save the hotkey to \(Settings.fileURL.path)")
        }
        Logger.info("Hotkey changed to \(hotkey.display)")
        close()
    }

    private func showProblem(_ text: String) {
        hintLabel.stringValue = text
        hintLabel.textColor = .systemOrange
    }

    @objc private func useDefault() {
        shortcutLabel.stringValue = Hotkey.default.display
        apply(.default)
    }

    @objc private func cancel() {
        close()
    }

    private func close() {
        panel?.close()
    }

    /// Every way out ends here: Cancel, Esc, the close button, a recorded
    /// shortcut. Whatever happened, a shortcut must be live again afterwards.
    func windowWillClose(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        idleTimer?.invalidate()
        idleTimer = nil
        panel = nil
        hintLabel.textColor = .secondaryLabelColor

        if hotkeyManager.current == nil {
            let saved = Settings.load().hotkey
            if !hotkeyManager.register(saved) {
                Logger.error("Could not restore the hotkey \(saved.display)")
            }
        }
    }
}
