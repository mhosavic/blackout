import Foundation

public struct NotificationManager {

    /// Show a macOS notification using osascript (most reliable for CLI tools)
    static func showNotification(title: String, message: String) {
        let script = """
        display notification "\(message)" with title "\(title)"
        """
        // Failure is fine — notification is not critical
        Shell.run("/usr/bin/osascript", ["-e", script])
    }

    /// Show notification that blackout mode is enabled
    public static func showEnabled() {
        showNotification(
            title: "Blackout",
            message: "Screen blacked out. Run again to restore."
        )
    }

    /// Show notification that blackout mode is disabled
    public static func showDisabled() {
        showNotification(
            title: "Blackout",
            message: "Brightness restored."
        )
    }

    /// Shown when re-enabling sleep failed. The lid watcher's stdout goes to
    /// /dev/null, so on the auto-disable path this notification is the only way
    /// the user ever learns their Mac will not sleep.
    public static func showSleepRestoreFailed() {
        showNotification(
            title: "Blackout",
            message: "Could not re-enable sleep. Run: sudo pmset -a disablesleep 0"
        )
    }
}
