import Foundation

// Main entry point for blackout CLI tool
// Running this command toggles blackout mode on/off

func enable() {
    // Save current brightness, volume, and external display luminance
    let currentBrightness = BrightnessController.getBrightness()
    let currentVolume = AudioController.getVolume()
    let externalLuminance = ExternalDisplayController.getLuminance()

    // Start caffeinate to prevent sleep
    guard let pid = SleepController.preventSleep() else {
        print("Failed to start caffeinate")
        exit(1)
    }

    // Save state for later restoration
    StateManager.saveState(brightness: currentBrightness, volume: currentVolume, externalLuminance: externalLuminance, pid: pid)

    // Dim screens and mute audio
    BrightnessController.dimScreen()
    ExternalDisplayController.dim()
    AudioController.mute()

    // Show notification
    NotificationManager.showEnabled()

    print("Blackout: ENABLED")
    print("  Original brightness: \(String(format: "%.0f", currentBrightness * 100))%")
    if let extLum = externalLuminance {
        print("  External display: \(extLum)%")
    }
    print("  Original volume: \(currentVolume)%")
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
    AudioController.unmute()
    AudioController.setVolume(state.originalVolume)

    // Clear state file
    StateManager.clearState()

    // Show notification
    NotificationManager.showDisabled()

    print("Blackout: DISABLED")
    print("  Brightness restored to: \(String(format: "%.0f", state.originalBrightness * 100))%")
    if let extLum = state.externalLuminance {
        print("  External display restored to: \(extLum)%")
    }
    print("  Volume restored to: \(state.originalVolume)%")
}

// Toggle based on current state
if StateManager.isActive() {
    disable()
} else {
    enable()
}
