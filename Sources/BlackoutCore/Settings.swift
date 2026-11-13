import Foundation

/// When blackout mutes audio
public enum MutePolicy: String, Codable, CaseIterable {
    /// Only when no external display is present: with a monitor attached the
    /// Mac is still being used, and silence would be a surprise
    case auto
    case always
    case never
}

/// What a session does, saved in ~/.blackout/config.json and shared by the
/// hotkey, the menu and the CLI. Read when a session starts: changing a
/// setting never alters a session already running.
public struct Settings: Equatable {

    public var muteAudio: MutePolicy = .auto
    public var dimExternal = false
    public var keepAwakeLidClosed = true
    public var lockOnLidClose = true
    public var notifications = true

    public init() {}

    /// Overridable so tests can use a temporary directory
    public static var fileURL: URL = PathManager.configFile

    // MARK: - File

    /// Load the saved settings. Lenient key by key — a missing or invalid
    /// value takes its default — because one bad edit should not silently
    /// reset the other four choices.
    public static func load() -> Settings {
        var settings = Settings()
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return settings
        }

        if let raw = json["muteAudio"] as? String, let policy = MutePolicy(rawValue: raw) {
            settings.muteAudio = policy
        }
        // `as? Bool` alone would accept the numbers 0 and 1; only a JSON
        // boolean is a valid value here
        func bool(_ key: String) -> Bool? {
            guard let number = json[key] as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        settings.dimExternal = bool("dimExternal") ?? settings.dimExternal
        settings.keepAwakeLidClosed = bool("keepAwakeLidClosed") ?? settings.keepAwakeLidClosed
        settings.lockOnLidClose = bool("lockOnLidClose") ?? settings.lockOnLidClose
        settings.notifications = bool("notifications") ?? settings.notifications
        return settings
    }

    /// Save all five settings. Returns false if the file could not be written.
    @discardableResult
    public func save() -> Bool {
        let json: [String: Any] = [
            "muteAudio": muteAudio.rawValue,
            "dimExternal": dimExternal,
            "keepAwakeLidClosed": keepAwakeLidClosed,
            "lockOnLidClose": lockOnLidClose,
            "notifications": notifications
        ]
        do {
            try FileManager.default.createDirectory(
                at: Settings.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: Settings.fileURL, options: .atomic)
            ChangeNotifier.post()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Keys

    /// The names `blackout config` and the menu use, in display order
    public static let keys = ["mute", "dim-external", "lid", "lock", "notifications"]

    /// Change one setting by its key. Returns false, changing nothing, for an
    /// unknown key or a value that key does not accept.
    public mutating func set(key: String, value: String) -> Bool {
        if key == "mute" {
            guard let policy = MutePolicy(rawValue: value) else { return false }
            muteAudio = policy
            return true
        }

        let isOn: Bool
        switch value {
        case "on": isOn = true
        case "off": isOn = false
        default: return false
        }

        switch key {
        case "dim-external": dimExternal = isOn
        case "lid": keepAwakeLidClosed = isOn
        case "lock": lockOnLidClose = isOn
        case "notifications": notifications = isOn
        default: return false
        }
        return true
    }

    /// The current value of a key, in the form `set` accepts
    public func value(forKey key: String) -> String? {
        func word(_ isOn: Bool) -> String { isOn ? "on" : "off" }
        switch key {
        case "mute": return muteAudio.rawValue
        case "dim-external": return word(dimExternal)
        case "lid": return word(keepAwakeLidClosed)
        case "lock": return word(lockOnLidClose)
        case "notifications": return word(notifications)
        default: return nil
        }
    }
}
