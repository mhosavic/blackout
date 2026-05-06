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
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        process.waitUntilExit()
        Logger.info("Blackout toggled, exit code: \(process.terminationStatus)")
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

func setupSignalHandlers() {
    // Handle SIGTERM (from launchctl unload)
    signal(SIGTERM) { _ in
        Logger.info("Received SIGTERM, shutting down")
        removePIDFile()
        exit(0)
    }

    // Handle SIGINT (Ctrl+C)
    signal(SIGINT) { _ in
        Logger.info("Received SIGINT, shutting down")
        removePIDFile()
        exit(0)
    }
}

// MARK: - Main

Logger.info("Blackout daemon starting")
Logger.info("PID: \(ProcessInfo.processInfo.processIdentifier)")

// Set up signal handlers
setupSignalHandlers()

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
