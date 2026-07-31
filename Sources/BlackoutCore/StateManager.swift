import Foundation

public struct BlackoutState: Codable {
    public let originalBrightness: Double
    public let originalVolume: Int?
    public let externalLuminance: Int?
    public let caffeinatePID: Int32
    // Optional so state files written by older versions still decode
    public let sleepDisabled: Bool?
    public let activatedAt: Date
}

public struct StateManager {

    /// ~/.blackout.state — overridable so tests can use a temporary directory
    public static var stateFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".blackout.state")

    /// Check if a saved session exists. Any state file counts, even one whose
    /// caffeinate has died (crash/reboot): restoring from it is always safe,
    /// while re-capturing a dimmed screen as "original" would lose settings.
    public static func hasState() -> Bool {
        return FileManager.default.fileExists(atPath: stateFileURL.path)
    }

    /// Load the current state from disk
    public static func loadState() -> BlackoutState? {
        guard hasState() else { return nil }

        do {
            let data = try Data(contentsOf: stateFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(BlackoutState.self, from: data)
        } catch {
            print("Error loading state: \(error)")
            return nil
        }
    }

    /// Save the current state to disk. Returns false on failure so the caller
    /// can undo — a session without saved state could never be restored.
    public static func saveState(brightness: Double, volume: Int?, externalLuminance: Int?, pid: pid_t, sleepDisabled: Bool) -> Bool {
        let state = BlackoutState(
            originalBrightness: brightness,
            originalVolume: volume,
            externalLuminance: externalLuminance,
            caffeinatePID: pid,
            sleepDisabled: sleepDisabled,
            activatedAt: Date()
        )

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(state)
            try data.write(to: stateFileURL)
            return true
        } catch {
            print("Error saving state: \(error)")
            return false
        }
    }

    /// Clear the state file
    public static func clearState() {
        do {
            if hasState() {
                try FileManager.default.removeItem(at: stateFileURL)
            }
        } catch {
            print("Error clearing state: \(error)")
        }
    }
}
