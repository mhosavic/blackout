import Foundation

// Main entry point for blackout CLI tool
// Running this command toggles blackout mode on/off

// Parse command-line arguments
let args = CommandLine.arguments
let skipExternal = args.contains("--no-external") || args.contains("-n")
let noMuteFlag = args.contains("--no-mute") || args.contains("-m")
let noLidFlag = args.contains("--no-lid") || args.contains("-l")

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

// Auto-detect: skip muting if external monitor is connected (unless --no-mute forces it)
let hasExternalDisplay = ExternalDisplayController.isConnected()
let skipMute = noMuteFlag || hasExternalDisplay

// Show help if requested
if args.contains("--help") || args.contains("-h") {
    print("blackout - Toggle screen blackout mode")
    print("")
    print("Usage: blackout [options]")
    print("")
    print("Options:")
    print("  -n, --no-external  Skip dimming external monitors")
    print("  -m, --no-mute      Skip muting audio")
    print("  -l, --no-lid       Skip disabling lid-close sleep")
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
    print("after --setup-lid). Audio is automatically kept unmuted when an external")
    print("monitor is detected. Run again to restore original settings.")
    print("")
    print("Hotkey (when daemon installed): ⌃⌥⌘\\ (Ctrl+Option+Cmd+Backslash)")
    exit(0)
}

func enable(skipExternal: Bool, skipMute: Bool, skipLid: Bool) {
    // Save current brightness, volume, and external display luminance
    let currentBrightness = BrightnessController.getBrightness()
    let currentVolume = skipMute ? nil : AudioController.getVolume()
    let externalLuminance = skipExternal ? nil : ExternalDisplayController.getLuminance()

    // Start caffeinate to prevent sleep
    guard let pid = SleepController.preventSleep() else {
        print("Failed to start caffeinate")
        exit(1)
    }

    // Disable lid-close sleep; if sleep was already disabled system-wide
    // (e.g. by the user via pmset), leave it alone so disable() won't undo it
    var sleepDisabledByUs = false
    var sleepAlreadyDisabled = false
    if !skipLid {
        if SleepController.isSleepDisabled() {
            sleepAlreadyDisabled = true
        } else {
            sleepDisabledByUs = SleepController.disableLidSleep()
        }
    }

    // Save state for later restoration
    StateManager.saveState(brightness: currentBrightness, volume: currentVolume, externalLuminance: externalLuminance, pid: pid, sleepDisabled: sleepDisabledByUs)

    // Dim screens and mute audio
    BrightnessController.dimScreen()
    if !skipExternal {
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
        print("  External display: \(extLum)%")
    } else if skipExternal {
        print("  External display: skipped (--no-external)")
    }
    if let vol = currentVolume {
        print("  Original volume: \(vol)%")
    } else if noMuteFlag {
        print("  Audio: skipped (--no-mute)")
    } else if hasExternalDisplay {
        print("  Audio: skipped (external monitor detected)")
    }
    if sleepDisabledByUs {
        print("  Lid sleep: disabled (safe to close the lid)")
    } else if sleepAlreadyDisabled {
        print("  Lid sleep: already disabled system-wide")
    } else if noLidFlag {
        print("  Lid sleep: skipped (--no-lid)")
    } else {
        print("  Lid sleep: unavailable (run 'blackout --setup-lid' once to enable)")
    }
    print("  Run 'blackout' again to disable")
}

func disable() {
    guard let state = StateManager.loadState() else {
        print("No active blackout session found")
        exit(1)
    }

    // Stop caffeinate to allow sleep
    SleepController.allowSleep(pid: state.caffeinatePID)

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
    }
}

// Toggle based on current state
if StateManager.isActive() {
    disable()
} else {
    enable(skipExternal: skipExternal, skipMute: skipMute, skipLid: noLidFlag)
}
