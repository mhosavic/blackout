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
    let watching = LidLockController.watch(
        onLidClose: {
            guard let state = StateManager.loadState() else { exit(0) }
            // Undo the dim before locking. The panel may already be powering
            // down, so this is best-effort; the open handler is the one that
            // has to land.
            restoreDisplays(state: state)
            LidLockController.lockScreen()
        },
        onLidOpen: {
            guard let state = StateManager.loadState() else { exit(0) }
            // Without this the lock screen is a black rectangle and the
            // password field cannot be seen
            restoreDisplays(state: state)
        },
        onUnlock: {
            guard let state = StateManager.loadState() else { exit(0) }
            // Authenticating means the owner is back: end the session so the
            // restored brightness keeps telling the truth about blackout
            disable(state: state)
            exit(0)
        }
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

/// Bring the panels back to what the user had. Idempotent — disable() sets the
/// same values again — so the watcher can call it on every lid event.
func restoreDisplays(state: BlackoutState) {
    BrightnessController.setBrightness(state.originalBrightness)
    if let extLum = state.externalLuminance {
        ExternalDisplayController.setLuminance(extLum)
    }
}

func enable(dimExternal: Bool, noMute: Bool, noLid: Bool, noLock: Bool) {
    // Probe the external display once. When one is connected it stays the
    // user's working screen: audio stays on and it is not dimmed unless
    // --dim-external asks for the old dim-everything behavior
    let detectedLuminance = ExternalDisplayController.getLuminance()
    let hasExternalDisplay = detectedLuminance != nil
    let skipMute = noMute || hasExternalDisplay

    // An external display left on means the lid is a keyboard cover, not a
    // screen — docked clamshell work must not lock. With --dim-external
    // everything is dark and locking is the point.
    let externalLeftOn = hasExternalDisplay && !dimExternal
    let lockOnLid = !noLock && !externalLeftOn && LidLockController.isLockAvailable()

    // Save current brightness, volume, and external display luminance
    let currentBrightness = BrightnessController.getBrightness()
    let currentVolume = skipMute ? nil : AudioController.getVolume()
    let externalLuminance = dimExternal ? detectedLuminance : nil

    // Start caffeinate to prevent sleep
    guard let pid = SleepController.preventSleep() else {
        print("Failed to start caffeinate")
        exit(1)
    }

    // Disable lid-close sleep; if sleep was already disabled system-wide
    // (e.g. by the user via pmset), leave it alone so disable() won't undo it
    var sleepDisabledByUs = false
    var sleepAlreadyDisabled = false
    if !noLid {
        if SleepController.isSleepDisabled() {
            sleepAlreadyDisabled = true
        } else {
            sleepDisabledByUs = SleepController.disableLidSleep()
        }
    }

    let lidWatcherPID = lockOnLid ? LidLockController.startWatcher() : nil

    // Save state before changing anything visible; without it the session
    // could never be restored, so undo and bail if the write fails
    guard StateManager.saveState(brightness: currentBrightness, volume: currentVolume, externalLuminance: externalLuminance, pid: pid, sleepDisabled: sleepDisabledByUs, lidWatcherPID: lidWatcherPID) else {
        SleepController.allowSleep(pid: pid)
        if let watcherPID = lidWatcherPID {
            LidLockController.stopWatcher(pid: watcherPID)
        }
        if sleepDisabledByUs {
            _ = SleepController.restoreLidSleep()
        }
        print("Failed to save state — blackout not enabled")
        exit(1)
    }

    // Dim screens and mute audio
    BrightnessController.dimScreen()
    if externalLuminance != nil {
        ExternalDisplayController.dim()
    }
    if !skipMute {
        AudioController.mute()
    }

    // Show notification
    NotificationManager.showEnabled()

    print("Blackout: ENABLED")
    print("  Original brightness: \(String(format: "%.0f", currentBrightness * 100))%")
    if let extLum = externalLuminance {
        print("  External display: dimmed (was \(extLum)%)")
    } else if hasExternalDisplay {
        print("  External display: left on (--dim-external to dim)")
    }
    if let vol = currentVolume {
        print("  Original volume: \(vol)%")
    } else if noMute {
        print("  Audio: skipped (--no-mute)")
    } else if hasExternalDisplay {
        print("  Audio: skipped (external monitor detected)")
    }
    if sleepDisabledByUs {
        print("  Lid sleep: disabled (safe to close the lid)")
    } else if sleepAlreadyDisabled {
        print("  Lid sleep: already disabled system-wide")
    } else if noLid {
        print("  Lid sleep: skipped (--no-lid)")
    } else {
        print("  Lid sleep: unavailable (run 'blackout --setup-lid' once to enable)")
    }
    if lidWatcherPID != nil {
        print("  Lock on lid close: armed (unlocking ends blackout)")
    } else if noLock {
        print("  Lock on lid close: skipped (--no-lock)")
    } else if externalLeftOn {
        print("  Lock on lid close: skipped (external monitor left on)")
    } else if !LidLockController.isLockAvailable() {
        print("  Lock on lid close: unavailable (SACLockScreenImmediate not found)")
    } else {
        print("  Lock on lid close: failed to start the watcher")
    }
    print("  Run 'blackout' again to disable")
}

func disable(state: BlackoutState) {
    // Stop caffeinate to allow sleep — unless it already died (crash/reboot),
    // in which case the PID may have been reused by another process
    if SleepController.isProcessRunning(pid: state.caffeinatePID) {
        SleepController.allowSleep(pid: state.caffeinatePID)
    } else {
        print("Recovering stale session (caffeinate was no longer running)")
    }

    // Stop the lid watcher. Skip our own PID: on the unlock path this function
    // runs inside the watcher, and SIGTERMing ourselves here would abandon the
    // restore half-done. A dead or missing PID just means it already exited.
    if let watcherPID = state.lidWatcherPID,
       watcherPID != ProcessInfo.processInfo.processIdentifier,
       SleepController.isProcessRunning(pid: watcherPID) {
        LidLockController.stopWatcher(pid: watcherPID)
    }

    // Re-enable lid-close sleep if we disabled it
    var lidSleepRestored = false
    if state.sleepDisabled == true {
        lidSleepRestored = SleepController.restoreLidSleep()
    }

    // Restore original brightness, external display, and volume
    BrightnessController.setBrightness(state.originalBrightness)
    if let extLum = state.externalLuminance {
        ExternalDisplayController.setLuminance(extLum)
    }
    if let vol = state.originalVolume {
        AudioController.unmute()
        AudioController.setVolume(vol)
    }

    // Clear state file
    StateManager.clearState()

    // Show notification
    NotificationManager.showDisabled()

    print("Blackout: DISABLED")
    print("  Brightness restored to: \(String(format: "%.0f", state.originalBrightness * 100))%")
    if let extLum = state.externalLuminance {
        print("  External display restored to: \(extLum)%")
    }
    if let vol = state.originalVolume {
        print("  Volume restored to: \(vol)%")
    }
    if lidSleepRestored {
        print("  Lid sleep: re-enabled")
    } else if state.sleepDisabled == true {
        print("  WARNING: could not re-enable sleep!")
        print("  Your Mac will NOT sleep until you run: sudo pmset -a disablesleep 0")
        NotificationManager.showSleepRestoreFailed()
    }
}

// Toggle based on saved state
if StateManager.hasState() {
    if let state = StateManager.loadState() {
        disable(state: state)
    } else {
        print("State file is corrupt — clearing it.")
        print("Brightness, volume, or sleep settings may need manual restoring.")
        StateManager.clearState()
        exit(1)
    }
} else {
    enable(dimExternal: dimExternalFlag, noMute: noMuteFlag, noLid: noLidFlag, noLock: noLockFlag)
}
