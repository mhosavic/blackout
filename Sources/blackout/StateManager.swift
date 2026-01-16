import Foundation

struct BlackoutState: Codable {
    let originalBrightness: Double
    let originalVolume: Int?
    let externalLuminance: Int?
    let caffeinatePID: Int32
    let activatedAt: Date
}

struct StateManager {

    private static var stateFilePath: URL {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".blackout.state")
    }

    /// Check if blackout mode is currently active
    static func isActive() -> Bool {
        guard let state = loadState() else { return false }
        // Also verify the caffeinate process is still running
        return SleepController.isProcessRunning(pid: state.caffeinatePID)
    }

    /// Load the current state from disk
    static func loadState() -> BlackoutState? {
        guard FileManager.default.fileExists(atPath: stateFilePath.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: stateFilePath)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(BlackoutState.self, from: data)
        } catch {
            print("Error loading state: \(error)")
            return nil
        }
    }

    /// Save the current state to disk
    static func saveState(brightness: Double, volume: Int?, externalLuminance: Int?, pid: pid_t) {
        let state = BlackoutState(
            originalBrightness: brightness,
            originalVolume: volume,
            externalLuminance: externalLuminance,
            caffeinatePID: pid,
            activatedAt: Date()
        )

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(state)
            try data.write(to: stateFilePath)
        } catch {
            print("Error saving state: \(error)")
        }
    }

    /// Clear the state file
    static func clearState() {
        do {
            if FileManager.default.fileExists(atPath: stateFilePath.path) {
                try FileManager.default.removeItem(at: stateFilePath)
            }
        } catch {
            print("Error clearing state: \(error)")
        }
    }
}
