import Foundation

/// Minimal helper for spawning external commands
enum Shell {

    /// Run a command quietly, discarding its output.
    /// Returns the exit status, or nil if it failed to launch.
    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return nil
        }
    }

    /// Run a command and capture its trimmed stdout.
    /// Returns nil if it failed to launch or exited nonzero.
    static func output(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            // Drain the pipe before waiting so large output can't deadlock
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    /// Run a command attached to the terminal, so tools like sudo can prompt
    /// for a password. Uses posix_spawn directly rather than Process, because
    /// Process moves children into their own (background) process group,
    /// where reading the terminal stops them with SIGTTIN and the password
    /// prompt hangs forever. Spawning without POSIX_SPAWN_SETPGROUP keeps
    /// the child in our foreground group.
    /// Returns the exit status, or nil if it failed to launch.
    static func runInteractive(_ path: String, _ arguments: [String]) -> Int32? {
        var argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        guard posix_spawn(&pid, path, nil, nil, argv, environ) == 0 else { return nil }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno != EINTR { return nil }
        }
        // Extract the exit code from the wait status, mapping a signal
        // death to the shell convention of 128 + signal
        if (status & 0x7f) == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + (status & 0x7f)
    }
}
