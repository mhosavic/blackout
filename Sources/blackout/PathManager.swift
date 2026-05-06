import Foundation

struct PathManager {

    // MARK: - Base Directories

    static var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// ~/.blackout/ directory for daemon files
    static var blackoutDirectory: URL {
        homeDirectory.appendingPathComponent(".blackout")
    }

    /// ~/Library/LaunchAgents/ for LaunchAgent plist
    static var launchAgentsDirectory: URL {
        homeDirectory.appendingPathComponent("Library/LaunchAgents")
    }

    // MARK: - Daemon Files

    /// ~/.blackout/blackout-daemon binary
    static var daemonBinary: URL {
        blackoutDirectory.appendingPathComponent("blackout-daemon")
    }

    /// ~/.blackout/daemon.log
    static var daemonLog: URL {
        blackoutDirectory.appendingPathComponent("daemon.log")
    }

    /// ~/.blackout/config.json (future use)
    static var configFile: URL {
        blackoutDirectory.appendingPathComponent("config.json")
    }

    /// ~/.blackout/daemon.pid
    static var daemonPID: URL {
        blackoutDirectory.appendingPathComponent("daemon.pid")
    }

    // MARK: - LaunchAgent

    static let launchAgentLabel = "com.blackout.daemon"

    /// ~/Library/LaunchAgents/com.blackout.daemon.plist
    static var launchAgentPlist: URL {
        launchAgentsDirectory.appendingPathComponent("\(launchAgentLabel).plist")
    }

    // MARK: - Blackout Binary

    /// Path to the main blackout binary (searches common locations)
    static var blackoutBinary: URL? {
        let searchPaths = [
            homeDirectory.appendingPathComponent("bin/blackout"),
            URL(fileURLWithPath: "/usr/local/bin/blackout"),
            URL(fileURLWithPath: "/opt/homebrew/bin/blackout")
        ]

        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path.path) {
                return path
            }
        }
        return nil
    }

    // MARK: - Directory Management

    /// Create ~/.blackout/ directory if it doesn't exist
    static func ensureBlackoutDirectoryExists() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: blackoutDirectory.path) {
            try fm.createDirectory(at: blackoutDirectory, withIntermediateDirectories: true)
        }
    }

    /// Create ~/Library/LaunchAgents/ directory if it doesn't exist
    static func ensureLaunchAgentsDirectoryExists() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: launchAgentsDirectory.path) {
            try fm.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        }
    }
}
