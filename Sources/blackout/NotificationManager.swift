import Foundation

struct NotificationManager {

    /// Show a macOS notification using osascript (most reliable for CLI tools)
    static func showNotification(title: String, message: String) {
        let script = """
        display notification "\(message)" with title "\(title)"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        // Suppress output
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Silently fail - notification is not critical
        }
    }

    /// Show notification that blackout mode is enabled
    static func showEnabled() {
        showNotification(
            title: "Blackout",
            message: "Screen blacked out. Run again to restore."
        )
    }

    /// Show notification that blackout mode is disabled
    static func showDisabled() {
        showNotification(
            title: "Blackout",
            message: "Brightness restored."
        )
    }
}
