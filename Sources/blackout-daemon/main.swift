import Foundation
import AppKit

// MARK: - Path Constants

let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
let blackoutDirectory = homeDirectory.appendingPathComponent(".blackout")
let pidFile = blackoutDirectory.appendingPathComponent("daemon.pid")

// MARK: - Blackout Binary Discovery

func findBlackoutBinary() -> URL? {
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

// MARK: - Toggle Blackout

func toggleBlackout() {
    guard let blackoutPath = findBlackoutBinary() else {
        Logger.error("Could not find blackout binary")
        return
    }

    Logger.info("Executing blackout: \(blackoutPath.path)")

    let process = Process()
    process.executableURL = blackoutPath

    // Capture output so failures are diagnosable from the log
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    do {
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            Logger.info("Blackout toggled")
        } else {
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Logger.error("Blackout exited \(process.terminationStatus): \(output)")
        }
    } catch {
        Logger.error("Failed to run blackout: \(error)")
    }
}

// MARK: - PID File Management

func writePIDFile() {
    let pid = ProcessInfo.processInfo.processIdentifier
    do {
        try FileManager.default.createDirectory(at: blackoutDirectory, withIntermediateDirectories: true)
        try "\(pid)".write(to: pidFile, atomically: true, encoding: .utf8)
        Logger.info("Wrote PID file: \(pid)")
    } catch {
        Logger.error("Failed to write PID file: \(error)")
    }
}

func removePIDFile() {
    try? FileManager.default.removeItem(at: pidFile)
    Logger.info("Removed PID file")
}

// MARK: - Signal Handling

/// Shutdown signals are handled via DispatchSource because raw signal()
/// handlers may not safely touch files or Foundation (async-signal-safety).
/// They run on a dedicated queue, not main, so the daemon stays killable
/// even if the main thread is ever blocked. The sources must stay
/// referenced for the lifetime of the daemon.
func makeSignalSources() -> [DispatchSourceSignal] {
    let signalQueue = DispatchQueue(label: "com.blackout.daemon.signals")
    let signals: [(Int32, String)] = [(SIGTERM, "SIGTERM"), (SIGINT, "SIGINT")]
    return signals.map { sig, name in
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
        source.setEventHandler {
            Logger.info("Received \(name), shutting down")
            removePIDFile()
            exit(0)
        }
        source.resume()
        return source
    }
}

// MARK: - Main

Logger.info("Blackout daemon starting")
Logger.info("PID: \(ProcessInfo.processInfo.processIdentifier)")

// Set up signal handlers (kept referenced until exit)
let signalSources = makeSignalSources()

// Write PID file
writePIDFile()

// Create hotkey manager
let hotkeyManager = HotkeyManager {
    toggleBlackout()
}

// Register hotkey
guard hotkeyManager.register() else {
    Logger.error("Failed to register hotkey, exiting")
    removePIDFile()
    exit(1)
}

Logger.info("Daemon running, press ⌃⌥⌘\\ to toggle blackout")

// Run the application event loop
// This is required for Carbon event handlers to work
let app = NSApplication.shared
app.setActivationPolicy(.accessory) // Run as background app (no dock icon)
app.run()
