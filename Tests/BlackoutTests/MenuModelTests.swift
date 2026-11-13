import Testing
import Foundation
import BlackoutCore

struct MenuModelTests {

    private let healthy = Health(lidSetupInstalled: true, m1ddcInstalled: true, lockAvailable: true)
    private let now = ISO8601DateFormatter().date(from: "2026-11-13T15:00:00Z")!

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private var runningState: BlackoutState {
        BlackoutState(
            originalBrightness: 0.62, originalVolume: nil, externalLuminance: nil,
            caffeinatePID: 1001, sleepDisabled: true, lidWatcherPID: 2002,
            activatedAt: ISO8601DateFormatter().date(from: "2026-11-13T14:36:19Z")!,
            summary: SessionSummary(audio: .leftOnExternalDisplay, external: .leftOn, lidSleep: .disabled, lidLock: .armed))
    }

    private func menu(
        on: Bool = false,
        corrupt: Bool = false,
        externalOnline: Bool = false,
        health: Health? = nil,
        _ change: (inout Settings) -> Void = { _ in }
    ) -> [MenuItemModel] {
        var settings = Settings()
        change(&settings)
        return MenuModel.build(
            state: on && !corrupt ? runningState : nil,
            stateFileExists: on,
            externalOnline: externalOnline,
            settings: settings,
            health: health ?? healthy,
            now: now,
            calendar: utc
        )
    }

    private func warnings(_ items: [MenuItemModel]) -> [String] {
        items.compactMap { if case .warning(let text) = $0 { return text } else { return nil } }
    }

    private func toggle(_ items: [MenuItemModel], titled title: String) -> (action: MenuAction, isOn: Bool)? {
        for item in items {
            if case .toggle(let itemTitle, let action, let isOn) = item, itemTitle == title { return (action, isOn) }
        }
        return nil
    }

    @Test func offMenuHasTurnOnAndNoSessionSection() {
        let items = menu()
        #expect(items[0] == .header("Blackout is off"))
        #expect(items[1] == .action(title: "Turn On", action: .turnOn, showsHotkey: true))
        #expect(!items.contains(.header("This session")))
        #expect(items.suffix(2) == [
            .action(title: "Open Log", action: .openLog, showsHotkey: false),
            .action(title: "Quit Blackout", action: .quit, showsHotkey: false)
        ])
    }

    /// The menu item names the explicit action, never "toggle": a menu
    /// drawn a moment before the state changed must not do the opposite
    /// of what it says
    @Test func onMenuHasTurnOffAndSessionLines() {
        let items = menu(on: true, externalOnline: true)
        #expect(items[0] == .header("Blackout is on · since 14:36"))
        #expect(items[1] == .action(title: "Turn Off", action: .turnOff, showsHotkey: true))

        let start = items.firstIndex(of: .header("This session"))
        #expect(start != nil)
        guard let start else { return }
        #expect(Array(items[(start + 1)...(start + 5)]) == [
            .info("Built-in display dimmed (was 62%)"),
            .info("External display left on"),
            .info("Audio left on (external display connected)"),
            .info("Awake with the lid closed"),
            .info("Won't lock while the external display is on")
        ])
    }

    @Test func settingsReflectTheFile() {
        let defaults = menu()
        #expect(toggle(defaults, titled: "Keep awake with the lid closed")?.isOn == true)
        #expect(toggle(defaults, titled: "Lock when the lid closes")?.isOn == true)
        #expect(toggle(defaults, titled: "Dim the external display too")?.isOn == false)
        #expect(toggle(defaults, titled: "Show notifications")?.isOn == true)

        let changed = menu { $0.lockOnLidClose = false; $0.dimExternal = true; $0.muteAudio = .never }
        #expect(toggle(changed, titled: "Lock when the lid closes")?.isOn == false)
        #expect(toggle(changed, titled: "Dim the external display too")?.isOn == true)
        #expect(changed.contains(.submenu(title: "Mute audio", items: [
            .toggle(title: "Only without an external display", action: .set(key: "mute", value: "auto"), isOn: false),
            .toggle(title: "Always", action: .set(key: "mute", value: "always"), isOn: false),
            .toggle(title: "Never", action: .set(key: "mute", value: "never"), isOn: true)
        ])))
    }

    @Test func menuOffersToChangeTheHotkeyAndShowsTheCurrentOne() {
        #expect(menu().contains(.action(title: "Change Hotkey (⌃⌥⌘\\)…", action: .changeHotkey, showsHotkey: false)))

        let custom = menu { $0.hotkey = Hotkey(keyCode: 11, modifiers: Hotkey.command | Hotkey.shift, keyLabel: "B") }
        #expect(custom.contains(.action(title: "Change Hotkey (⇧⌘B)…", action: .changeHotkey, showsHotkey: false)))
    }

    @Test func toggleActionsFlipTheValue() {
        let items = menu()
        #expect(toggle(items, titled: "Lock when the lid closes")?.action == .set(key: "lock", value: "off"))
        #expect(toggle(items, titled: "Dim the external display too")?.action == .set(key: "dim-external", value: "on"))
    }

    /// Every action a settings item carries must be one Settings accepts,
    /// or clicking it would silently do nothing
    @Test func everySettingsActionIsAccepted() {
        var actions: [MenuAction] = []
        for item in menu() {
            if case .toggle(_, let action, _) = item { actions.append(action) }
            if case .submenu(_, let children) = item {
                for child in children {
                    if case .toggle(_, let action, _) = child { actions.append(action) }
                }
            }
        }
        #expect(actions.count == 8)
        for action in actions {
            guard case .set(let key, let value) = action else {
                Issue.record("settings item carries \(action)")
                continue
            }
            var settings = Settings()
            let accepted = settings.set(key: key, value: value)
            #expect(accepted, "\(key) \(value)")
        }
    }

    @Test func settingsHeaderMentionsNextSessionOnlyWhileOn() {
        #expect(menu().contains(.header("Settings")))
        #expect(menu(on: true).contains(.header("Settings (apply the next time Blackout turns on)")))
    }

    @Test func warnsWhenLidSetupMissingAndSettingOn() {
        let health = Health(lidSetupInstalled: false, m1ddcInstalled: true, lockAvailable: true)
        #expect(warnings(menu(health: health)) == ["Lid setup missing: run \"blackout setup-lid\" in Terminal"])
    }

    /// A missing setup is only a problem for a behavior that is switched on
    @Test func noWarningForAFeatureThatIsOff() {
        let broken = Health(lidSetupInstalled: false, m1ddcInstalled: false, lockAvailable: false)
        let items = menu(health: broken) { $0.keepAwakeLidClosed = false; $0.lockOnLidClose = false }
        #expect(warnings(items).isEmpty)
    }

    @Test func warnsWhenM1ddcMissingAndDimExternalOn() {
        let health = Health(lidSetupInstalled: true, m1ddcInstalled: false, lockAvailable: true)
        #expect(warnings(menu(health: health)).isEmpty)
        #expect(warnings(menu(health: health) { $0.dimExternal = true }) == ["m1ddc is not installed: external displays cannot be dimmed"])
    }

    @Test func warnsWhenTheBuiltinCannotBeSwitchedOff() {
        let health = Health(lidSetupInstalled: true, m1ddcInstalled: true, lockAvailable: true, builtinOffAvailable: false)
        #expect(warnings(menu(health: health)).isEmpty)
        #expect(warnings(menu(health: health) { $0.builtinOff = true })
            == ["This macOS cannot switch the built-in display off: it is dimmed instead"])
    }

    @Test func warnsWhenLockCallMissing() {
        let health = Health(lidSetupInstalled: true, m1ddcInstalled: true, lockAvailable: false)
        #expect(warnings(menu(health: health)) == ["macOS lock call missing: the lid cannot lock the screen"])
    }

    @Test func healthyMenuHasNoWarnings() {
        #expect(warnings(menu()).isEmpty)
        #expect(warnings(menu(on: true)).isEmpty)
    }

    /// A state file that cannot be read is still a session: the menu must
    /// offer the way out, not "Turn On"
    @Test func corruptStateShowsOnWithRestoreHint() {
        let items = menu(on: true, corrupt: true)
        #expect(items[0] == .header("Blackout is on (state file unreadable)"))
        #expect(items[1] == .action(title: "Turn Off", action: .turnOff, showsHotkey: true))
        #expect(!items.contains(.header("This session")))
        #expect(warnings(items) == ["Turn Off clears the state file; brightness, volume or sleep may need restoring by hand"])
    }
}
