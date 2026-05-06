import Foundation
import Carbon

class HotkeyManager {

    // Hotkey: ⌃⌥⌘\ (Control + Option + Command + Backslash)
    // Key code 0x2A is backslash (\)
    private static let hotkeyKeyCode: UInt32 = 0x2A
    private static let hotkeyModifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey)

    private var hotkeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let callback: () -> Void

    init(callback: @escaping () -> Void) {
        self.callback = callback
    }

    /// Register the global hotkey
    func register() -> Bool {
        // Define the hotkey ID
        var hotkeyID = EventHotKeyID()
        hotkeyID.signature = OSType(0x424C4B54) // 'BLKT' in hex
        hotkeyID.id = 1

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

        // Register the hotkey
        var hotkeyRefTemp: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            HotkeyManager.hotkeyKeyCode,
            HotkeyManager.hotkeyModifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRefTemp
        )

        guard registerStatus == noErr else {
            Logger.error("Failed to register hotkey: \(registerStatus)")
            return false
        }
        self.hotkeyRef = hotkeyRefTemp

        Logger.info("Hotkey registered: ⌃⌥⌘\\")
        return true
    }

    /// Unregister the global hotkey
    func unregister() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
            Logger.info("Hotkey unregistered")
        }

        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    /// Handle hotkey press
    private func handleHotkey() {
        Logger.info("Hotkey pressed")
        callback()
    }

    deinit {
        unregister()
    }
}
