import Foundation
import BlackoutCore

// Main entry point for blackout CLI tool
// Running this command toggles blackout mode on/off

// Parse command-line arguments
let args = CommandLine.arguments
let dimExternalFlag = args.contains("--dim-external") || args.contains("-e")
let noMuteFlag = args.contains("--no-mute") || args.contains("-m")
let noLidFlag = args.contains("--no-lid") || args.contains("-l")
let noLockFlag = args.contains("--no-lock") || args.contains("-k")

// Internal mode: the detached watcher spawned by enable(). Not in --help —
// users never run it directly, but it is visible in `ps` as `blackout --lid-watch`.
// Each handler reloads state: if the session ended without this process being
// killed, there is nothing left to act on.
if args.contains("--lid-watch") {
    let session = Session()
    func act(_ action: Session.WatcherAction) {
        if action == .stop { exit(0) }
    }
    let watching = LidLockController.watch(
        onLidClose: { act(session.handleLidClose()) },
        onLidOpen: { screenLocked in act(session.handleLidOpen(screenLocked: screenLocked)) },
        onUnlock: { act(session.handleUnlock(notify: Settings.load().notifications)) }
    )
    exit(watching ? 0 : 1)
}

// One-time setup for passwordless lid-sleep control
if args.contains("--setup-lid") {
    SleepController.setupLid()
    exit(0)
}

// Daemon commands
if args.contains("--install") {
    DaemonController.install()
    exit(0)
}

if args.contains("--uninstall") {
    DaemonController.uninstall()
    exit(0)
}

if args.contains("--status") {
    DaemonController.status()
    exit(0)
}

// Show help if requested
if args.contains("--help") || args.contains("-h") {
    print("blackout - Toggle screen blackout mode")
    print("")
    print("Usage: blackout [options]")
    print("")
    print("Options:")
    print("  -e, --dim-external Also dim external monitors (untouched by default)")
    print("  -m, --no-mute      Skip muting audio")
    print("  -l, --no-lid       Skip disabling lid-close sleep")
    print("  -k, --no-lock      Skip locking the screen when the lid closes")
    print("  -h, --help         Show this help message")
    print("")
    print("Daemon commands:")
    print("  --install          Install hotkey daemon (runs at login)")
    print("  --uninstall        Remove hotkey daemon")
    print("  --status           Show daemon status")
    print("")
    print("Setup commands:")
    print("  --setup-lid        One-time setup so blackout can keep the Mac awake")
    print("                     with the lid closed (writes /etc/sudoers.d/blackout)")
    print("")
    print("Running 'blackout' toggles blackout mode on/off.")
    print("When enabled: dims screen, mutes audio, prevents sleep (even lid close,")
    print("after --setup-lid) and locks the screen when the lid closes — unlocking")
    print("then ends blackout. Audio is automatically kept unmuted when an external")
    print("monitor is detected, which also leaves the lid lock off. Run again to")
    print("restore original settings.")
    print("")
    print("Hotkey (when daemon installed): ⌃⌥⌘\\ (Ctrl+Option+Cmd+Backslash)")
    exit(0)
}

func printEnabled(_ state: BlackoutState) {
    print("Blackout: ENABLED")
    print("  Original brightness: \(String(format: "%.0f", state.originalBrightness * 100))%")
    if let summary = state.summary {
        print("  External display: \(summary.external.rawValue)")
        print("  Audio: \(summary.audio.rawValue)")
        print("  Lid sleep: \(summary.lidSleep.rawValue)")
        print("  Lock on lid close: \(summary.lidLock.rawValue)")
    }
    print("  Run 'blackout' again to disable")
}

func printDisabled(_ report: Session.DisableReport) {
    let state = report.state
    if report.recoveredStaleSession {
        print("Recovering stale session (caffeinate was no longer running)")
    }
    print("Blackout: DISABLED")
    print("  Brightness restored to: \(String(format: "%.0f", state.originalBrightness * 100))%")
    if let extLum = state.externalLuminance {
        print("  External display restored to: \(extLum)%")
    }
    if let vol = state.originalVolume {
        print("  Volume restored to: \(vol)%")
    }
    if report.lidSleepRestoreFailed {
        print("  WARNING: could not re-enable sleep!")
        print("  Your Mac will NOT sleep until you run: sudo pmset -a disablesleep 0")
    } else if state.sleepDisabled == true {
        print("  Lid sleep: re-enabled")
    }
}

// Toggle based on saved state
let session = Session()
var settings = Settings.load()
if dimExternalFlag { settings.dimExternal = true }
if noMuteFlag { settings.muteAudio = .never }
if noLidFlag { settings.keepAwakeLidClosed = false }
if noLockFlag { settings.lockOnLidClose = false }

if StateManager.hasState() {
    switch session.disable(notify: settings.notifications) {
    case .disabled(let report):
        printDisabled(report)
    case .alreadyOff:
        print("Blackout is already off")
    case .corruptState:
        print("State file is corrupt — clearing it.")
        print("Brightness, volume, or sleep settings may need manual restoring.")
        exit(1)
    }
} else {
    switch session.enable(settings: settings) {
    case .enabled(let report):
        printEnabled(report.state)
    case .alreadyOn:
        print("Blackout is already on")
    case .busy:
        print("Another blackout command is still running")
        exit(1)
    case .failed(let message):
        print(message)
        exit(1)
    }
}
