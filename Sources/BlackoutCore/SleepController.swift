import Foundation

public struct SleepController {

    /// Start caffeinate to prevent display sleep
    /// Returns the process ID of the caffeinate process
    public static func preventSleep() -> pid_t? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-d"]  // Prevent display sleep

        do {
            try process.run()
            return process.processIdentifier
        } catch {
            print("Error starting caffeinate: \(error)")
            return nil
        }
    }

    /// Kill the caffeinate process to allow sleep again
    public static func allowSleep(pid: pid_t) {
        kill(pid, SIGTERM)
    }

    /// Check if a process with given PID is still running
    public static func isProcessRunning(pid: pid_t) -> Bool {
        // kill with signal 0 checks if process exists without actually killing it
        return kill(pid, 0) == 0
    }

    // MARK: - Lid-Close Sleep (pmset disablesleep)

    /// Check whether system-wide sleep is currently disabled (pmset SleepDisabled)
    public static func isSleepDisabled() -> Bool {
        guard let output = Shell.output("/usr/bin/pmset", ["-g"]) else { return false }
        return parseSleepDisabled(fromPmsetOutput: output)
    }

    /// pmset -g lists "SleepDisabled 1" only while sleep is disabled;
    /// the line is absent otherwise
    public static func parseSleepDisabled(fromPmsetOutput output: String) -> Bool {
        for line in output.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.split(whereSeparator: \.isWhitespace).last == "1"
        }
        return false
    }

    /// Disable all system sleep so closing the lid keeps processes running.
    /// Requires the passwordless sudo rule installed by `blackout --setup-lid`.
    /// Returns true on success.
    public static func disableLidSleep() -> Bool {
        return setSleepDisabled(1)
    }

    /// Re-enable normal system sleep (lid close sleeps the machine again)
    public static func restoreLidSleep() -> Bool {
        return setSleepDisabled(0)
    }

    private static func setSleepDisabled(_ value: Int) -> Bool {
        // sudo -n fails immediately instead of prompting, so the hotkey daemon
        // (no TTY) degrades gracefully when the sudoers rule is missing
        return Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", "\(value)"]) == 0
    }

    /// Check whether the passwordless sudo rule is installed, without running pmset
    public static func isLidSetupInstalled() -> Bool {
        return Shell.run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"]) == 0
    }

    // MARK: - Setup

    /// The sudoers rule allowing exactly the two disablesleep commands, nothing else
    public static func sudoersRule(for user: String) -> String {
        return "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0\n"
    }

    /// One-time setup: install the sudoers rule so blackout can toggle
    /// disablesleep without a password. Interactive (sudo asks for the
    /// user's password).
    public static func setupLid() {
        let sudoersPath = "/etc/sudoers.d/blackout"
        let rule = sudoersRule(for: NSUserName())

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("blackout-sudoers")
        do {
            try rule.write(to: tempFile, atomically: true, encoding: .utf8)
        } catch {
            print("Error writing temporary sudoers file: \(error)")
            exit(1)
        }
        defer { try? FileManager.default.removeItem(at: tempFile) }

        // Validate syntax before installing anything into /etc/sudoers.d
        guard Shell.runInteractive("/usr/sbin/visudo", ["-c", "-q", "-f", tempFile.path]) == 0 else {
            print("Error: generated sudoers rule failed visudo validation")
            exit(1)
        }

        print("Installing \(sudoersPath) (your password may be required)...")
        let status = Shell.runInteractive("/usr/bin/sudo", ["/usr/bin/install", "-m", "0440", "-o", "root", "-g", "wheel", tempFile.path, sudoersPath])

        if status == 0 {
            print("Done. Blackout will now disable lid-close sleep while active.")
            print("Undo anytime with: sudo rm \(sudoersPath)")
        } else {
            print("Setup failed (sudo declined or was cancelled)")
            exit(1)
        }
    }
}
