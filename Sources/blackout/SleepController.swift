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
}
