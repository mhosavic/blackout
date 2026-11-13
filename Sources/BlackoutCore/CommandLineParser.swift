import Foundation

/// Per-run choices from the command line. nil means "not given": the saved
/// setting stands.
public struct Overrides: Equatable {
    public var dimExternal: Bool?
    public var mute: Bool?
    public var lid: Bool?
    public var lock: Bool?

    public init() {}

    public var isEmpty: Bool {
        return self == Overrides()
    }

    public func applied(to settings: Settings) -> Settings {
        var settings = settings
        if let dimExternal { settings.dimExternal = dimExternal }
        if let mute { settings.muteAudio = mute ? .always : .never }
        if let lid { settings.keepAwakeLidClosed = lid }
        if let lock { settings.lockOnLidClose = lock }
        return settings
    }
}

public enum Command: Equatable {
    case toggle(Overrides)
    case on(Overrides)
    case off
    case status
    case configShow
    case configSet(key: String, value: String)
    /// Change the global shortcut: open the recorder in the menu bar app,
    /// or go back to the default
    case hotkey(reset: Bool)
    case install
    case uninstall
    case setupLid
    /// Internal: the detached watcher a session spawns
    case lidWatch
    case help
}

public struct ParseError: Error, Equatable {
    public let message: String
}

public enum CommandLineParser {

    private static let commands: [String: Command] = [
        "toggle": .toggle(Overrides()),
        "on": .on(Overrides()),
        "off": .off,
        "status": .status, "--status": .status,
        "config": .configShow,
        "hotkey": .hotkey(reset: false),
        "install": .install, "--install": .install,
        "uninstall": .uninstall, "--uninstall": .uninstall,
        "setup-lid": .setupLid, "--setup-lid": .setupLid,
        "--lid-watch": .lidWatch,
        "help": .help, "--help": .help, "-h": .help
    ]

    private static let overrideFlags: [String: (WritableKeyPath<Overrides, Bool?>, Bool)] = [
        "-e": (\.dimExternal, true), "--dim-external": (\.dimExternal, true), "--no-dim-external": (\.dimExternal, false),
        "--mute": (\.mute, true), "-m": (\.mute, false), "--no-mute": (\.mute, false),
        "--lid": (\.lid, true), "-l": (\.lid, false), "--no-lid": (\.lid, false),
        "--lock": (\.lock, true), "-k": (\.lock, false), "--no-lock": (\.lock, false)
    ]

    /// Parse the arguments after the program name. Anything not recognized
    /// is an error rather than ignored: the default action changes the
    /// screen, so a typo must not fall through to it.
    public static func parse(_ arguments: [String]) -> Result<Command, ParseError> {
        var command: Command?
        var overrides = Overrides()
        var firstOverrideFlag: String?
        var configArguments: [String] = []
        var hotkeyReset = false

        for argument in arguments {
            if let (keyPath, value) = overrideFlags[argument] {
                if let existing = overrides[keyPath: keyPath], existing != value {
                    return .failure(ParseError(message: "\(argument) contradicts an earlier option"))
                }
                overrides[keyPath: keyPath] = value
                firstOverrideFlag = firstOverrideFlag ?? argument
            } else if let parsed = commands[argument], !(command == .configShow && configArguments.count < 2) {
                guard command == nil else {
                    return .failure(ParseError(message: "Only one command at a time (got '\(argument)' as well)"))
                }
                command = parsed
            } else if command == .configShow, configArguments.count < 2, !argument.hasPrefix("-") {
                configArguments.append(argument)
            } else if command == .hotkey(reset: false), !hotkeyReset, argument == "default" {
                hotkeyReset = true
            } else {
                return .failure(ParseError(message: "Unknown argument: \(argument)"))
            }
        }

        switch command ?? .toggle(Overrides()) {
        case .toggle:
            return .success(.toggle(overrides))
        case .on:
            return .success(.on(overrides))
        case let other:
            if let flag = firstOverrideFlag {
                return .failure(ParseError(message: "\(flag) only applies when turning blackout on"))
            }
            if other == .hotkey(reset: false) { return .success(.hotkey(reset: hotkeyReset)) }
            guard other == .configShow else { return .success(other) }
            switch configArguments.count {
            case 0: return .success(.configShow)
            case 2: return .success(.configSet(key: configArguments[0], value: configArguments[1]))
            default: return .failure(ParseError(message: "config takes a key and a value, or nothing to show the settings"))
            }
        }
    }
}
