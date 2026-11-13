import Foundation
import AppKit
import BlackoutCore

// MARK: - PID File Management

func writePIDFile() {
    let pid = ProcessInfo.processInfo.processIdentifier
    do {
        try PathManager.ensureBlackoutDirectoryExists()
        try "\(pid)".write(to: PathManager.daemonPID, atomically: true, encoding: .utf8)
        Logger.info("Wrote PID file: \(pid)")
    } catch {
        Logger.error("Failed to write PID file: \(error)")
    }
}

func removePIDFile() {
    try? FileManager.default.removeItem(at: PathManager.daemonPID)
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

Logger.info("Blackout menu bar app starting")
Logger.info("PID: \(ProcessInfo.processInfo.processIdentifier)")

// Two instances would mean two icons and a hotkey that fails to register.
// Found by bundle identifier rather than the PID file, which a crash or a
// power cut leaves behind and whose number a later process can reuse — that
// would wrongly keep the app down for the whole login session.
if let bundleID = Bundle.main.bundleIdentifier {
    let ownPID = ProcessInfo.processInfo.processIdentifier
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != ownPID }
    if !others.isEmpty {
        Logger.info("Already running (PID \(others[0].processIdentifier)), exiting")
        exit(0)
    }
}

// Set up signal handlers (kept referenced until exit)
let signalSources = makeSignalSources()

// Write PID file
writePIDFile()

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // No dock icon; the status item is the whole UI

let toggler = Toggler()
let statusItemController = StatusItemController(toggler: toggler)

// Create hotkey manager
let hotkeyManager = HotkeyManager {
    toggler.run("toggle") {
        statusItemController.refreshIcon()
    }
}

// Register hotkey
guard hotkeyManager.register() else {
    Logger.error("Failed to register hotkey, exiting")
    removePIDFile()
    exit(1)
}

Logger.info("Running, press ⌃⌥⌘\\ to toggle blackout")

// Run the application event loop
// This is required for Carbon event handlers to work
app.run()
