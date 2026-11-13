import Foundation

/// The words for a session and the settings, in one place so the terminal
/// and the menu can never describe the same thing two ways.
public enum SessionText {

    // MARK: - Session

    /// "Blackout is on · since 14:36". A state file that exists but cannot
    /// be read still counts as on: there is a session to end.
    public static func headline(state: BlackoutState?, stateFileExists: Bool, now: Date, calendar: Calendar = .current) -> String {
        guard stateFileExists else { return "Blackout is off" }
        guard let state else { return "Blackout is on (state file unreadable)" }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        // Left on overnight, the time alone would read as today
        formatter.dateFormat = calendar.isDate(state.activatedAt, inSameDayAs: now) ? "HH:mm" : "MMM d, HH:mm"
        return "Blackout is on · since \(formatter.string(from: state.activatedAt))"
    }

    /// What the running session did, one line per thing it can touch.
    /// `externalOnline` is the live display state, which decides the lid-lock
    /// line: that decision is made when the lid closes, not when the session
    /// started.
    public static func sessionLines(state: BlackoutState, externalOnline: Bool) -> [String] {
        var lines = ["Built-in display dimmed (was \(percent(state.originalBrightness)))"]

        guard let summary = state.summary else {
            return lines + legacyLines(state: state, externalOnline: externalOnline)
        }

        switch summary.external {
        case .none: break
        case .dimmed: lines.append(externalDimmedLine(state))
        case .leftOn: lines.append("External display left on")
        case .unreachable: lines.append("External display not reachable by m1ddc (treated as absent)")
        }

        switch summary.audio {
        case .muted: lines.append(audioMutedLine(state))
        case .leftOnBySetting: lines.append("Audio left on (setting)")
        case .leftOnExternalDisplay: lines.append("Audio left on (external display connected)")
        }

        switch summary.lidSleep {
        case .disabled: lines.append("Awake with the lid closed")
        case .alreadyDisabled: lines.append("Awake with the lid closed (sleep was already disabled system-wide)")
        case .offBySetting: lines.append("Sleeps when the lid closes (setting)")
        case .setupMissing: lines.append("Sleeps when the lid closes (run \"blackout setup-lid\" once)")
        }

        switch summary.lidLock {
        case .armed: lines.append(armedLockLine(state: state, externalOnline: externalOnline))
        case .offBySetting: lines.append("Does not lock when the lid closes (setting)")
        case .unavailable: lines.append("Cannot lock when the lid closes (macOS lock call missing)")
        case .watcherFailed: lines.append("Cannot lock when the lid closes (watcher failed to start)")
        }

        return lines
    }

    /// A session started by a version that recorded no summary: say what
    /// the restore keys imply and nothing more
    private static func legacyLines(state: BlackoutState, externalOnline: Bool) -> [String] {
        var lines: [String] = []
        if state.externalLuminance != nil {
            lines.append(externalDimmedLine(state))
        }
        lines.append(state.originalVolume != nil ? audioMutedLine(state) : "Audio left on")
        if state.sleepDisabled == true {
            lines.append("Awake with the lid closed")
        }
        if state.lidWatcherPID != nil {
            lines.append(armedLockLine(state: state, externalOnline: externalOnline))
        }
        return lines
    }

    private static func armedLockLine(state: BlackoutState, externalOnline: Bool) -> String {
        let locks = LidLockController.shouldLockOnLidClose(
            externalOnline: externalOnline,
            externalWasDimmed: state.externalLuminance != nil
        )
        return locks ? "Locks when the lid closes" : "Won't lock while the external display is on"
    }

    private static func externalDimmedLine(_ state: BlackoutState) -> String {
        guard let luminance = state.externalLuminance else { return "External display dimmed" }
        return "External display dimmed (was \(luminance)%)"
    }

    private static func audioMutedLine(_ state: BlackoutState) -> String {
        guard let volume = state.originalVolume else { return "Audio muted" }
        return "Audio muted (was \(volume)%)"
    }

    private static func percent(_ fraction: Double) -> String {
        return "\(Int((fraction * 100).rounded()))%"
    }

    // MARK: - Settings

    public static func title(forSetting key: String) -> String {
        switch key {
        case "mute": return "Mute audio"
        case "dim-external": return "Dim the external display too"
        case "lid": return "Keep awake with the lid closed"
        case "lock": return "Lock when the lid closes"
        case "notifications": return "Show notifications"
        default: return key
        }
    }

    public static func label(for policy: MutePolicy) -> String {
        switch policy {
        case .auto: return "Only without an external display"
        case .always: return "Always"
        case .never: return "Never"
        }
    }

    /// One aligned line per setting: key, current value, what it means and
    /// the values it accepts — everything `blackout config` needs to change it
    public static func settingsLines(_ settings: Settings) -> [String] {
        return Settings.keys.map { key in
            let value = settings.value(forKey: key) ?? ""
            let accepted = key == "mute" ? MutePolicy.allCases.map(\.rawValue).joined(separator: "|") : "on|off"
            return key.padding(toLength: 15, withPad: " ", startingAt: 0)
                + value.padding(toLength: 8, withPad: " ", startingAt: 0)
                + "\(title(forSetting: key)) (\(accepted))"
        }
    }
}
