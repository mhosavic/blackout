import Foundation

// Main entry point for blackout CLI tool
// Running this command toggles blackout mode on/off

func enable() {
    // Save current brightness and volume before dimming/muting
    let currentBrightness = BrightnessController.getBrightness()
    let currentVolume = AudioController.getVolume()

    // Start caffeinate to prevent sleep
    guard let pid = SleepController.preventSleep() else {
        print("Failed to start caffeinate")
        exit(1)
    }

    // Save state for later restoration
    StateManager.saveState(brightness: currentBrightness, volume: currentVolume, pid: pid)

    // Dim the screen and mute audio
    BrightnessController.dimScreen()
    AudioController.mute()

    // Show notification
    NotificationManager.showEnabled()

    print("Blackout: ENABLED")
    print("  Original brightness: \(String(format: "%.0f", currentBrightness * 100))%")
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

    // Restore original brightness and volume
    BrightnessController.setBrightness(state.originalBrightness)
    AudioController.unmute()
    AudioController.setVolume(state.originalVolume)

    // Clear state file
    StateManager.clearState()

    // Show notification
    NotificationManager.showDisabled()

    print("Blackout: DISABLED")
    print("  Brightness restored to: \(String(format: "%.0f", state.originalBrightness * 100))%")
    print("  Volume restored to: \(state.originalVolume)%")
}

// Toggle based on current state
if StateManager.isActive() {
    disable()
} else {
    enable()
}
