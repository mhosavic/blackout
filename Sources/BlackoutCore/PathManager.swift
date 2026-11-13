import Foundation

public struct PathManager {

    // MARK: - Base Directories

    public static var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// ~/.blackout/ directory for settings and runtime files
    public static var blackoutDirectory: URL {
        homeDirectory.appendingPathComponent(".blackout")
    }

    /// ~/Library/LaunchAgents/ for LaunchAgent plist
    public static var launchAgentsDirectory: URL {
        homeDirectory.appendingPathComponent("Library/LaunchAgents")
    }

    // MARK: - Installed App

    /// ~/Applications/Blackout.app — per-user, so installing needs no sudo
    public static var appBundle: URL {
        homeDirectory.appendingPathComponent("Applications/Blackout.app")
    }

    /// The menu bar app inside the bundle; what the LaunchAgent starts
    public static var installedMenuApp: URL {
        appBundle.appendingPathComponent("Contents/MacOS/blackout-menu")
    }

    /// The CLI inside the bundle, beside the app so the two stay one version
    public static var installedCLI: URL {
        appBundle.appendingPathComponent("Contents/MacOS/blackout")
    }

    /// ~/bin/blackout — a symlink to the bundled CLI
    public static var cliLink: URL {
        homeDirectory.appendingPathComponent("bin/blackout")
    }

    // MARK: - Runtime Files

    /// ~/.blackout/blackout-daemon — the hotkey daemon from before 2.0,
    /// removed on install
    public static var legacyDaemonBinary: URL {
        blackoutDirectory.appendingPathComponent("blackout-daemon")
    }

    /// ~/.blackout/daemon.log
    public static var daemonLog: URL {
        blackoutDirectory.appendingPathComponent("daemon.log")
    }

    /// ~/.blackout/config.json — the saved settings
    public static var configFile: URL {
        blackoutDirectory.appendingPathComponent("config.json")
    }

    /// ~/.blackout/daemon.pid
    public static var daemonPID: URL {
        blackoutDirectory.appendingPathComponent("daemon.pid")
    }

    /// ~/.blackout/lock — held while a session is being started or ended
    public static var lockFile: URL {
        blackoutDirectory.appendingPathComponent("lock")
    }

    // MARK: - LaunchAgent

    public static let launchAgentLabel = "com.blackout.daemon"

    /// ~/Library/LaunchAgents/com.blackout.daemon.plist
    public static var launchAgentPlist: URL {
        launchAgentsDirectory.appendingPathComponent("\(launchAgentLabel).plist")
    }

    // MARK: - Directory Management

    /// Create ~/.blackout/ directory if it doesn't exist
    public static func ensureBlackoutDirectoryExists() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: blackoutDirectory.path) {
            try fm.createDirectory(at: blackoutDirectory, withIntermediateDirectories: true)
        }
    }

    /// Create ~/Library/LaunchAgents/ directory if it doesn't exist
    public static func ensureLaunchAgentsDirectoryExists() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: launchAgentsDirectory.path) {
            try fm.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        }
    }
}
