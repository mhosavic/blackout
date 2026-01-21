import Foundation

// Main entry point for blackout CLI tool
// Running this command toggles blackout mode on/off

// Parse command-line arguments
let args = CommandLine.arguments
let skipExternal = args.contains("--no-external") || args.contains("-n")
let noMuteFlag = args.contains("--no-mute") || args.contains("-m")

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
    print("  -h, --help         Show this help message")
    print("")
    print("Running 'blackout' toggles blackout mode on/off.")
    print("When enabled: dims screen, mutes audio, prevents sleep.")
    print("Audio is automatically kept unmuted when an external monitor is detected.")
    print("Run again to restore original settings.")
    exit(0)
}

func enable(skipExternal: Bool, skipMute: Bool) {
    // Save current brightness, volume, and external display luminance
    let currentBrightness = BrightnessController.getBrightness()
    let currentVolume = skipMute ? nil : AudioController.getVolume()
    let externalLuminance = skipExternal ? nil : ExternalDisplayController.getLuminance()

    // Start caffeinate to prevent sleep
    guard let pid = SleepController.preventSleep() else {
        print("Failed to start caffeinate")
        exit(1)
    }

    // Save state for later restoration
    StateManager.saveState(brightness: currentBrightness, volume: currentVolume, externalLuminance: externalLuminance, pid: pid)

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
    print("  Run 'blackout' again to disable")
}

func disable() {
    guard let state = StateManager.loadState() else {
        print("No active blackout session found")
        exit(1)
    }

    // Stop caffeinate to allow sleep
    SleepController.allowSleep(pid: state.caffeinatePID)

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
}

// Toggle based on current state
if StateManager.isActive() {
    disable()
} else {
    enable(skipExternal: skipExternal, skipMute: skipMute)
}
