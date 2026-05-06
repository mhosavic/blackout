import Foundation

struct DaemonController {

    // MARK: - Install

    /// Install the daemon and LaunchAgent
    static func install() {
        print("Installing blackout daemon...")

        // 1. Find the daemon binary in the build directory
        guard let daemonSource = findDaemonBinary() else {
            print("Error: Could not find blackout-daemon binary.")
            print("Make sure to build with: swift build -c release")
            exit(1)
        }

        // 2. Create ~/.blackout/ directory
        do {
            try PathManager.ensureBlackoutDirectoryExists()
        } catch {
            print("Error creating ~/.blackout directory: \(error)")
            exit(1)
        }

        // 3. Copy daemon binary
        let fm = FileManager.default
        let daemonDest = PathManager.daemonBinary

        do {
            if fm.fileExists(atPath: daemonDest.path) {
                try fm.removeItem(at: daemonDest)
            }
            try fm.copyItem(at: daemonSource, to: daemonDest)
            // Make executable
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: daemonDest.path)
            print("  Copied daemon to \(daemonDest.path)")
        } catch {
            print("Error copying daemon binary: \(error)")
            exit(1)
        }

        // 4. Create LaunchAgent plist
        do {
            try PathManager.ensureLaunchAgentsDirectoryExists()
            let plist = generateLaunchAgentPlist()
            try plist.write(to: PathManager.launchAgentPlist, atomically: true, encoding: .utf8)
            print("  Created LaunchAgent at \(PathManager.launchAgentPlist.path)")
        } catch {
            print("Error creating LaunchAgent plist: \(error)")
            exit(1)
        }

        // 5. Load the LaunchAgent
        let loadResult = runLaunchctl(["load", PathManager.launchAgentPlist.path])
        if loadResult == 0 {
            print("  Started daemon")
        } else {
            print("  Warning: launchctl load returned \(loadResult)")
        }

        print("")
        print("Installation complete!")
        print("Press ⌃⌥⌘\\ (Ctrl+Option+Cmd+Backslash) to toggle blackout")
        print("")
        print("The daemon will start automatically at login.")
        print("Use 'blackout --status' to check status.")
        print("Use 'blackout --uninstall' to remove.")
    }

    // MARK: - Uninstall

    /// Uninstall the daemon and LaunchAgent
    static func uninstall() {
        print("Uninstalling blackout daemon...")

        let fm = FileManager.default

        // 1. Unload LaunchAgent
        if fm.fileExists(atPath: PathManager.launchAgentPlist.path) {
            let unloadResult = runLaunchctl(["unload", PathManager.launchAgentPlist.path])
            if unloadResult == 0 {
                print("  Stopped daemon")
            }
            try? fm.removeItem(at: PathManager.launchAgentPlist)
            print("  Removed LaunchAgent")
        }

        // 2. Remove ~/.blackout/ directory
        if fm.fileExists(atPath: PathManager.blackoutDirectory.path) {
            try? fm.removeItem(at: PathManager.blackoutDirectory)
            print("  Removed ~/.blackout directory")
        }

        print("")
        print("Uninstall complete!")
    }

    // MARK: - Status

    /// Show daemon status
    static func status() {
        let fm = FileManager.default

        // Check if LaunchAgent is installed
        let agentInstalled = fm.fileExists(atPath: PathManager.launchAgentPlist.path)

        // Check if daemon binary exists
        let binaryExists = fm.fileExists(atPath: PathManager.daemonBinary.path)

        // Check if daemon is running (via PID file)
        var daemonRunning = false
        var daemonPID: Int32?

        if let pidString = try? String(contentsOf: PathManager.daemonPID, encoding: .utf8),
           let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) {
            // Check if process is actually running
            if kill(pid, 0) == 0 {
                daemonRunning = true
                daemonPID = pid
            }
        }

        print("Blackout Daemon Status")
        print("======================")
        print("")
        print("LaunchAgent: \(agentInstalled ? "installed" : "not installed")")
        print("  Path: \(PathManager.launchAgentPlist.path)")
        print("")
        print("Daemon binary: \(binaryExists ? "installed" : "not installed")")
        print("  Path: \(PathManager.daemonBinary.path)")
        print("")
        print("Daemon process: \(daemonRunning ? "RUNNING" : "NOT RUNNING")")
        if let pid = daemonPID {
            print("  PID: \(pid)")
        }
        print("")
        print("Hotkey: ⌃⌥⌘\\ (Ctrl+Option+Cmd+Backslash)")

        // Show log tail if exists
        if fm.fileExists(atPath: PathManager.daemonLog.path) {
            print("")
            print("Recent log entries:")
            print("-------------------")
            if let logContent = try? String(contentsOf: PathManager.daemonLog, encoding: .utf8) {
                let lines = logContent.components(separatedBy: .newlines)
                let recentLines = lines.suffix(5)
                for line in recentLines where !line.isEmpty {
                    print("  \(line)")
                }
            }
        }
    }

    // MARK: - Helpers

    /// Find the daemon binary in common build locations
    private static func findDaemonBinary() -> URL? {
        let fm = FileManager.default

        // Search paths in order of priority
        let searchPaths = [
            // Release build (preferred)
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build/release/blackout-daemon"),
            // Debug build
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build/debug/blackout-daemon"),
            // Alongside main binary
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("blackout-daemon")
        ]

        for path in searchPaths {
            if fm.isExecutableFile(atPath: path.path) {
                return path
            }
        }

        return nil
    }

    /// Generate LaunchAgent plist content
    private static func generateLaunchAgentPlist() -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(PathManager.launchAgentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(PathManager.daemonBinary.path)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>
            <key>ProcessType</key>
            <string>Background</string>
            <key>StandardOutPath</key>
            <string>\(PathManager.daemonLog.path)</string>
            <key>StandardErrorPath</key>
            <string>\(PathManager.daemonLog.path)</string>
        </dict>
        </plist>
        """
    }

    /// Run launchctl command
    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
