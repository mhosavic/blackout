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
    func otherInstances() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ownPID && !$0.isTerminated }
    }
    // On a reinstall the instance just stopped can linger in the list for a
    // moment. Exiting 0 over it would be final — launchd does not restart a
    // clean exit — so look twice before believing it.
    if !otherInstances().isEmpty {
        Thread.sleep(forTimeInterval: 1)
        if let other = otherInstances().first {
            Logger.info("Already running (PID \(other.processIdentifier)), exiting")
            exit(0)
        }
    }
}

// Set up signal handlers (kept referenced until exit)
let signalSources = makeSignalSources()

// Write PID file
writePIDFile()

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // No dock icon; the status item is the whole UI

let toggler = Toggler()

// Create hotkey manager. The status item is created after it, so the
// callback reaches it through a variable set a few lines down.
var refreshStatusIcon: () -> Void = {}
let hotkeyManager = HotkeyManager {
    toggler.run("toggle") {
        refreshStatusIcon()
    }
}
let hotkeyRecorder = HotkeyRecorder(hotkeyManager: hotkeyManager)
let statusItemController = StatusItemController(toggler: toggler, onChangeHotkey: {
    hotkeyRecorder.show()
})
refreshStatusIcon = { statusItemController.refreshIcon() }

// Register the saved hotkey; if macOS refuses it, the default is better
// than no hotkey at all
let savedHotkey = Settings.load().hotkey
if !hotkeyManager.register(savedHotkey) {
    guard savedHotkey != .default, hotkeyManager.register(.default) else {
        Logger.error("Failed to register hotkey, exiting")
        removePIDFile()
        exit(1)
    }
    Logger.error("Fell back to the default hotkey \(Hotkey.default.display)")
}

// Follow a hotkey changed outside the recorder: 'blackout hotkey default',
// or config.json edited by hand
ChangeNotifier.observe {
    let wanted = Settings.load().hotkey
    guard !hotkeyRecorder.isRecording, hotkeyManager.current != wanted else { return }
    let previous = hotkeyManager.current
    if !hotkeyManager.register(wanted), let previous {
        _ = hotkeyManager.register(previous)
    }
}
ChangeNotifier.observeHotkeyRecorderRequest {
    hotkeyRecorder.show()
}

Logger.info("Running, press \(hotkeyManager.current?.display ?? "the hotkey") to toggle blackout")

// Run the application event loop
// This is required for Carbon event handlers to work
app.run()
