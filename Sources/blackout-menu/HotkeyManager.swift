import Foundation
import Carbon
import BlackoutCore

class HotkeyManager {

    private var hotkeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let callback: () -> Void

    /// The shortcut currently registered with macOS, nil while none is
    private(set) var current: Hotkey?

    init(callback: @escaping () -> Void) {
        self.callback = callback
    }

    /// Register `hotkey` as the global shortcut, replacing the one in place.
    /// On failure the previous shortcut is gone too; the caller decides what
    /// to fall back to.
    func register(_ hotkey: Hotkey) -> Bool {
        guard installHandlerIfNeeded() else { return false }
        unregisterHotkey()

        // Define the hotkey ID
        var hotkeyID = EventHotKeyID()
        hotkeyID.signature = OSType(0x424C4B54) // 'BLKT' in hex
        hotkeyID.id = 1

        var hotkeyRefTemp: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.modifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRefTemp
        )

        guard registerStatus == noErr else {
            Logger.error("Failed to register hotkey \(hotkey.display): \(registerStatus)")
            return false
        }
        self.hotkeyRef = hotkeyRefTemp
        self.current = hotkey

        Logger.info("Hotkey registered: \(hotkey.display)")
        return true
    }

    /// The Carbon handler that receives every hot key press; installed once
    private func installHandlerIfNeeded() -> Bool {
        guard eventHandler == nil else { return true }

        // Store self pointer for callback
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Define the event type
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // Install event handler
        let handlerCallback: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.handleHotkey()
            return noErr
        }

        var handlerRef: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handlerCallback,
            1,
            &eventType,
            selfPtr,
            &handlerRef
        )

        guard installStatus == noErr else {
            Logger.error("Failed to install event handler: \(installStatus)")
            return false
        }
        self.eventHandler = handlerRef
        return true
    }

    /// Stop listening for the shortcut, e.g. while a new one is being
    /// recorded — pressing the old one must not toggle blackout then
    func unregisterHotkey() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
            current = nil
        }
    }

    /// Handle hotkey press
    private func handleHotkey() {
        Logger.info("Hotkey pressed")
        callback()
    }

    deinit {
        unregisterHotkey()
        if let handler = eventHandler {
            RemoveEventHandler(handler)
        }
    }
}
