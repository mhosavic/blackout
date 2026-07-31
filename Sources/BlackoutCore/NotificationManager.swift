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
}
