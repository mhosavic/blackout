import Foundation

/// Installing and removing the menu bar app: the bundle in ~/Applications,
/// the `blackout` command on the PATH, and the LaunchAgent that starts the
/// app at login.
public enum AppInstaller {

    // MARK: - Install

    /// Install the bundle this CLI is running from. `make install` builds
    /// that bundle and calls this; the CLI and the menu bar app travel in it
    /// together, so they can never be two different versions.
    public static func install() {
        let fm = FileManager.default

        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath(),
              let source = enclosingBundle(ofExecutable: executable.path),
              fm.isExecutableFile(atPath: source.appendingPathComponent("Contents/MacOS/blackout-menu").path) else {
            print("Error: 'blackout install' has to run from inside Blackout.app.")
            print("In the repository, run: make install")
            exit(1)
        }

        print("Installing Blackout...")
        let destination = PathManager.appBundle

        // Stop the running app first (also the pre-2.0 hotkey daemon: same label)
        if fm.fileExists(atPath: PathManager.launchAgentPlist.path) {
            Shell.run("/bin/launchctl", ["unload", PathManager.launchAgentPlist.path])
        }

        do {
            if source.standardizedFileURL != destination.standardizedFileURL {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Remove, then copy — never write through the old files. A
                // session's lid watcher may be running from them, and macOS
                // kills a signed binary whose file changes underneath it;
                // removing only unlinks, so the watcher keeps running.
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.copyItem(at: source, to: destination)
                print("  Installed \(destination.path)")
            }

            try fm.createDirectory(at: PathManager.cliLink.deletingLastPathComponent(), withIntermediateDirectories: true)
            // attributesOfItem does not follow links, so this also sees a
            // dangling symlink, which fileExists would report as absent
            if (try? fm.attributesOfItem(atPath: PathManager.cliLink.path)) != nil {
                try fm.removeItem(at: PathManager.cliLink)
            }
            try fm.createSymbolicLink(at: PathManager.cliLink, withDestinationURL: PathManager.installedCLI)
            print("  Linked \(PathManager.cliLink.path)")

            // The pre-2.0 daemon binary; the app bundle replaces it
            try? fm.removeItem(at: PathManager.legacyDaemonBinary)

            try PathManager.ensureBlackoutDirectoryExists()
            try PathManager.ensureLaunchAgentsDirectoryExists()
            let plist = launchAgentPlist(
                programPath: PathManager.installedMenuApp.path,
                logPath: PathManager.daemonLog.path)
            try plist.write(to: PathManager.launchAgentPlist, atomically: true, encoding: .utf8)
        } catch {
            print("Error: \(error.localizedDescription)")
            exit(1)
        }

        let loadResult = Shell.run("/bin/launchctl", ["load", PathManager.launchAgentPlist.path]) ?? -1
        if loadResult == 0 {
            print("  Started the menu bar app")
        } else {
            print("  Warning: launchctl load returned \(loadResult)")
        }

        print("")
        print("Done. Blackout is in the menu bar and starts at login.")
        print("Press ⌃⌥⌘\\ (Ctrl+Option+Cmd+Backslash) to toggle blackout.")
        if !(ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains(Substring(PathManager.cliLink.deletingLastPathComponent().path)) {
            print("Note: \(PathManager.cliLink.deletingLastPathComponent().path) is not on your PATH; add it to use 'blackout' from a terminal.")
        }
    }

    // MARK: - Uninstall

    /// Remove the app, the command and the LaunchAgent. Settings and the
    /// lid-sleep sudo rule stay; uninstall.sh removes those too.
    public static func uninstall() {
        let fm = FileManager.default
        print("Uninstalling Blackout...")

        // End a running session first: once the command is gone nothing
        // could, and the Mac would stay awake with sleep disabled
        if StateManager.hasState() {
            _ = Session().disable(notify: false)
            guard !StateManager.hasState() else {
                print("Error: blackout is on and could not be turned off. Nothing was removed.")
                exit(1)
            }
            print("  Turned blackout off")
        }

        if fm.fileExists(atPath: PathManager.launchAgentPlist.path) {
            Shell.run("/bin/launchctl", ["unload", PathManager.launchAgentPlist.path])
            try? fm.removeItem(at: PathManager.launchAgentPlist)
            print("  Removed the LaunchAgent")
        }

        // Only a link into the app: a `blackout` the user put there some
        // other way is not ours to delete
        if let target = try? fm.destinationOfSymbolicLink(atPath: PathManager.cliLink.path),
           target == PathManager.installedCLI.path {
            try? fm.removeItem(at: PathManager.cliLink)
            print("  Removed \(PathManager.cliLink.path)")
        }

        if fm.fileExists(atPath: PathManager.appBundle.path) {
            try? fm.removeItem(at: PathManager.appBundle)
            print("  Removed \(PathManager.appBundle.path)")
        }

        try? fm.removeItem(at: PathManager.legacyDaemonBinary)
        try? fm.removeItem(at: PathManager.daemonPID)

        print("")
        print("Uninstalled. Your settings are kept in \(PathManager.configFile.path).")
        print("To remove those and the lid-sleep sudo rule as well, run uninstall.sh from the repository.")
    }

    // MARK: - Status

    /// Whether the menu bar app is installed and running, with the tail of
    /// its log
    public static func statusLines() -> [String] {
        let fm = FileManager.default
        var lines: [String] = []

        var runningPID: Int32?
        if let pidString = try? String(contentsOf: PathManager.daemonPID, encoding: .utf8),
           let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)),
           SleepController.processName(pid: pid) == "blackout-menu" {
            runningPID = pid
        }

        let installed = fm.fileExists(atPath: PathManager.installedMenuApp.path)
        if let runningPID {
            lines.append("Menu bar app: running (PID \(runningPID))")
        } else if installed {
            lines.append("Menu bar app: installed, not running")
        } else {
            lines.append("Menu bar app: not installed (run 'make install' in the repository)")
        }
        let startsAtLogin = fm.fileExists(atPath: PathManager.launchAgentPlist.path)
        lines.append("  Starts at login: \(startsAtLogin ? "yes" : "no")")
        lines.append("  Hotkey: ⌃⌥⌘\\ (Ctrl+Option+Cmd+Backslash)")

        if let log = try? String(contentsOf: PathManager.daemonLog, encoding: .utf8) {
            let recent = log.components(separatedBy: .newlines).filter { !$0.isEmpty }.suffix(5)
            if !recent.isEmpty {
                lines.append("  Recent log (\(PathManager.daemonLog.path)):")
                lines += recent.map { "    \($0)" }
            }
        }
        return lines
    }

    // MARK: - Helpers

    /// The .app an executable lives in, or nil if it is not at
    /// <Name>.app/Contents/MacOS/<executable>. Pass a path with symlinks
    /// resolved: through ~/bin/blackout the path says nothing about the app.
    public static func enclosingBundle(ofExecutable path: String) -> URL? {
        let macOS = URL(fileURLWithPath: path).deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS",
              contents.lastPathComponent == "Contents",
              bundle.pathExtension == "app" else { return nil }
        return bundle
    }

    /// LaunchAgent plist content
    public static func launchAgentPlist(programPath: String, logPath: String) -> String {
        func escaped(_ text: String) -> String {
            return text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(PathManager.launchAgentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(escaped(programPath))</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>
            <key>ProcessType</key>
            <string>Interactive</string>
            <key>StandardOutPath</key>
            <string>\(escaped(logPath))</string>
            <key>StandardErrorPath</key>
            <string>\(escaped(logPath))</string>
        </dict>
        </plist>
        """
    }
}
