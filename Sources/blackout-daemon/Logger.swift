import Foundation

struct Logger {

    private static let maxLogSize = 1_000_000 // 1MB
    private static let timestampFormatter = ISO8601DateFormatter()

    private static var logFileURL: URL {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".blackout/daemon.log")
    }

    /// Log a message with timestamp
    static func log(_ message: String) {
        let timestamp = timestampFormatter.string(from: Date())
        let logLine = "[\(timestamp)] \(message)\n"

        rotateIfNeeded()

        let fm = FileManager.default
        let logPath = logFileURL.path

        if fm.fileExists(atPath: logPath) {
            if let fileHandle = FileHandle(forWritingAtPath: logPath) {
                defer { try? fileHandle.close() }
                fileHandle.seekToEndOfFile()
                if let data = logLine.data(using: .utf8) {
                    fileHandle.write(data)
                }
            }
        } else {
            // Ensure directory exists
            let dir = logFileURL.deletingLastPathComponent()
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? logLine.write(to: logFileURL, atomically: true, encoding: .utf8)
        }
    }

    /// Log an info message
    static func info(_ message: String) {
        log("INFO: \(message)")
    }

    /// Log an error message
    static func error(_ message: String) {
        log("ERROR: \(message)")
    }

    /// Log a debug message
    static func debug(_ message: String) {
        log("DEBUG: \(message)")
    }

    /// Rotate log file if it exceeds max size
    private static func rotateIfNeeded() {
        let fm = FileManager.default
        let logPath = logFileURL.path

        guard fm.fileExists(atPath: logPath),
              let attrs = try? fm.attributesOfItem(atPath: logPath),
              let size = attrs[.size] as? Int,
              size > maxLogSize else {
            return
        }

        // Rotate: rename current to .old, start fresh
        let oldPath = logPath + ".old"
        try? fm.removeItem(atPath: oldPath)
        try? fm.moveItem(atPath: logPath, toPath: oldPath)
    }
}
