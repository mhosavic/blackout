import Foundation

/// What a click in the menu does
public enum MenuAction: Equatable {
    case turnOn
    case turnOff
    /// Change a setting, in the form `Settings.set(key:value:)` accepts
    case set(key: String, value: String)
    /// Open the window that records a new global shortcut
    case changeHotkey
    case openLog
    case quit
}

/// One row of the menu, described without AppKit so the menu's content can
/// be tested; the app only draws these
public enum MenuItemModel: Equatable {
    case header(String)
    case info(String)
    case warning(String)
    case separator
    case action(title: String, action: MenuAction, showsHotkey: Bool)
    case toggle(title: String, action: MenuAction, isOn: Bool)
    case submenu(title: String, items: [MenuItemModel])
}

public enum MenuModel {

    /// Build the whole menu from what is on disk right now. `state` is nil
    /// with `stateFileExists` true when the file cannot be read. `health` is
    /// the last known setup check.
    public static func build(
        state: BlackoutState?,
        stateFileExists: Bool,
        externalOnline: Bool,
        settings: Settings,
        health: Health,
        now: Date,
        calendar: Calendar = .current
    ) -> [MenuItemModel] {
        var items: [MenuItemModel] = [
            .header(SessionText.headline(state: state, stateFileExists: stateFileExists, now: now, calendar: calendar)),
            // The explicit action, not a toggle: a menu drawn just before the
            // state changed must still do what it says
            stateFileExists
                ? .action(title: "Turn Off", action: .turnOff, showsHotkey: true)
                : .action(title: "Turn On", action: .turnOn, showsHotkey: true),
            .separator
        ]

        if let state {
            items.append(.header("This session"))
            items += SessionText.sessionLines(state: state, externalOnline: externalOnline).map { .info($0) }
            items.append(.separator)
        }

        items.append(.header(stateFileExists ? "Settings (apply the next time Blackout turns on)" : "Settings"))
        for key in Settings.keys {
            let title = SessionText.title(forSetting: key)
            if key == "mute" {
                items.append(.submenu(title: title, items: MutePolicy.allCases.map { policy in
                    .toggle(
                        title: SessionText.label(for: policy),
                        action: .set(key: key, value: policy.rawValue),
                        isOn: settings.muteAudio == policy
                    )
                }))
            } else if key == "builtin-off" {
                // A choice of two named behaviors rather than a checkbox:
                // each label says what happens to the windows, which a bare
                // "turn off" does not
                items.append(.submenu(title: "Built-in display when docked", items: [
                    .toggle(
                        title: "Dim it (windows stay where they are)",
                        action: .set(key: key, value: "off"),
                        isOn: !settings.builtinOff
                    ),
                    .toggle(
                        title: "Turn it off (notifications and its windows move to the external display)",
                        action: .set(key: key, value: "on"),
                        isOn: settings.builtinOff
                    )
                ]))
            } else {
                let isOn = settings.value(forKey: key) == "on"
                items.append(.toggle(title: title, action: .set(key: key, value: isOn ? "off" : "on"), isOn: isOn))
            }
        }
        items.append(.action(title: "Change Hotkey (\(settings.hotkey.display))…", action: .changeHotkey, showsHotkey: false))
        items.append(.separator)

        let warnings = warnings(state: state, stateFileExists: stateFileExists, settings: settings, health: health)
        if !warnings.isEmpty {
            items += warnings.map { .warning($0) }
            items.append(.separator)
        }

        items.append(.action(title: "Open Log", action: .openLog, showsHotkey: false))
        items.append(.action(title: "Quit Blackout", action: .quit, showsHotkey: false))
        return items
    }

    /// Only for a behavior that is switched on and cannot work: a missing
    /// setup for something the user turned off is not a problem
    private static func warnings(state: BlackoutState?, stateFileExists: Bool, settings: Settings, health: Health) -> [String] {
        var warnings: [String] = []
        if stateFileExists && state == nil {
            warnings.append("Turn Off clears the state file; brightness, volume or sleep may need restoring by hand")
        }
        if settings.keepAwakeLidClosed && !health.lidSetupInstalled {
            warnings.append("Lid setup missing: run \"blackout setup-lid\" in Terminal")
        }
        if settings.dimExternal && !health.m1ddcInstalled {
            warnings.append("m1ddc is not installed: external displays cannot be dimmed")
        }
        if settings.builtinOff && !health.builtinOffAvailable {
            warnings.append("This macOS cannot switch the built-in display off: it is dimmed instead")
        }
        if settings.lockOnLidClose && !health.lockAvailable {
            warnings.append("macOS lock call missing: the lid cannot lock the screen")
        }
        return warnings
    }
}
