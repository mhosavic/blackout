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

    /// Run a command with inherited stdio, so tools like sudo and visudo can
    /// prompt and report errors directly to the terminal.
    /// Returns the exit status, or nil if it failed to launch.
    static func runInteractive(_ path: String, _ arguments: [String]) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return nil
        }
    }
}
