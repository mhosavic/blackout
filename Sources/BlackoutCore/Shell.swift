import Foundation

/// Minimal helper for spawning external commands
enum Shell {

    /// How long a command may run before it is killed. Everything blackout
    /// runs answers in well under a second; one that does not has hung, and
    /// would otherwise hold a toggle — and the session lock — indefinitely.
    static let timeout: TimeInterval = 10

    /// Stop `process` if it is still running after `timeout`: SIGTERM, then
    /// SIGKILL a second later for a child that ignores it (one stuck in a
    /// device call does). Cancel the returned item once the process has exited.
    private static func stopAfterTimeout(_ process: Process) -> DispatchWorkItem {
        let stop = DispatchWorkItem {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        return stop
    }

    /// Start a command and do not wait for it. stdio goes to /dev/null: the
    /// child may outlive us, and inheriting our stdout would hold open the
    /// pipe the menu bar app reads to EOF.
    static func spawn(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

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
            let stop = stopAfterTimeout(process)
            process.waitUntilExit()
            stop.cancel()
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
            let stop = stopAfterTimeout(process)
            // Drain the pipe before waiting so large output can't deadlock
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            stop.cancel()
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
        return waitForExit(pid)
    }

    /// Start a command in a session of its own and return its PID without
    /// waiting: it survives whatever stops its parent's process group.
    /// stdin is /dev/null; stdout and stderr are appended to `output`; no
    /// other descriptor is inherited. SIGTERM and SIGINT start at their
    /// defaults, since the menu bar app ignores both to handle them itself.
    static func spawnDetached(_ path: String, _ arguments: [String], output: URL) -> pid_t? {
        var argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGTERM)
        sigaddset(&defaults, SIGINT)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)

        var files: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&files)
        defer { posix_spawn_file_actions_destroy(&files) }
        posix_spawn_file_actions_addopen(&files, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&files, 1, output.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&files, 1, 2)

        var pid: pid_t = 0
        guard posix_spawn(&pid, path, &files, &attributes, argv, environ) == 0 else { return nil }
        return pid
    }

    /// Wait for a child to end and return its exit code, mapping a signal
    /// death to the shell convention of 128 + signal (-1 if it cannot be
    /// waited for)
    static func waitForExit(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno != EINTR { return -1 }
        }
        if (status & 0x7f) == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + (status & 0x7f)
    }
}
