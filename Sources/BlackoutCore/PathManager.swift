import Foundation

public struct PathManager {

    // MARK: - Base Directories

    public static var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// ~/.blackout/ directory for daemon files
    public static var blackoutDirectory: URL {
        homeDirectory.appendingPathComponent(".blackout")
    }

    /// ~/Library/LaunchAgents/ for LaunchAgent plist
    public static var launchAgentsDirectory: URL {
        homeDirectory.appendingPathComponent("Library/LaunchAgents")
    }

    // MARK: - Daemon Files

    /// ~/.blackout/blackout-daemon binary
    public static var daemonBinary: URL {
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
