import Foundation

struct SleepController {

    /// Start caffeinate to prevent display sleep
    /// Returns the process ID of the caffeinate process
    static func preventSleep() -> pid_t? {
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
    static func allowSleep(pid: pid_t) {
        kill(pid, SIGTERM)
    }

    /// Check if a process with given PID is still running
    static func isProcessRunning(pid: pid_t) -> Bool {
        // kill with signal 0 checks if process exists without actually killing it
        return kill(pid, 0) == 0
    }

    /// Check whether system-wide sleep is currently disabled (pmset SleepDisabled)
    static func isSleepDisabled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return false }
            for line in output.split(separator: "\n") where line.contains("SleepDisabled") {
                return line.hasSuffix("1")
            }
        } catch {
            print("Error reading pmset settings: \(error)")
        }
        return false
    }

    /// Disable all system sleep so closing the lid keeps processes running.
    /// Requires the passwordless sudo rule installed by `blackout --setup-lid`.
    /// Returns true on success.
    static func disableLidSleep() -> Bool {
        return setSleepDisabled(1)
    }

    /// Re-enable normal system sleep (lid close sleeps the machine again)
    static func restoreLidSleep() -> Bool {
        return setSleepDisabled(0)
    }

    private static func setSleepDisabled(_ value: Int) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        // -n fails immediately instead of prompting, so the hotkey daemon
        // (no TTY) degrades gracefully when the sudoers rule is missing
        process.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", "\(value)"]
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// One-time setup: install a sudoers rule allowing only the two pmset
    /// disablesleep commands to run without a password. Interactive (asks
    /// for the user's password via sudo).
    static func setupLid() {
        let sudoersPath = "/etc/sudoers.d/blackout"
        let user = NSUserName()
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0\n"

        let tempPath = NSTemporaryDirectory() + "blackout-sudoers"
        do {
            try rule.write(toFile: tempPath, atomically: true, encoding: .utf8)
        } catch {
            print("Error writing temporary sudoers file: \(error)")
            exit(1)
        }

        // Validate syntax before installing anything into /etc/sudoers.d
        if runCommand("/usr/sbin/visudo", ["-c", "-q", "-f", tempPath]) != 0 {
            print("Error: generated sudoers rule failed visudo validation")
            exit(1)
        }

        print("Installing \(sudoersPath) (your password may be required)...")
        let status = runCommand("/usr/bin/sudo", ["/usr/bin/install", "-m", "0440", "-o", "root", "-g", "wheel", tempPath, sudoersPath])
        try? FileManager.default.removeItem(atPath: tempPath)

        if status == 0 {
            print("Done. Blackout will now disable lid-close sleep while active.")
            print("Undo anytime with: sudo rm \(sudoersPath)")
        } else {
            print("Setup failed (sudo declined or was cancelled)")
            exit(1)
        }
    }

    private static func runCommand(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return 1
        }
    }
}
