import Foundation

public struct BlackoutState: Codable {
    public let originalBrightness: Double
    public let originalVolume: Int?
    public let externalLuminance: Int?
    public let caffeinatePID: Int32
    // Optional so state files written by older versions still decode
    public let sleepDisabled: Bool?
    public let lidWatcherPID: Int32?
    public let activatedAt: Date
    /// What the session decided and why — for display only, see init(from:)
    public let summary: SessionSummary?

    public init(originalBrightness: Double, originalVolume: Int?, externalLuminance: Int?, caffeinatePID: Int32, sleepDisabled: Bool?, lidWatcherPID: Int32?, activatedAt: Date, summary: SessionSummary?) {
        self.originalBrightness = originalBrightness
        self.originalVolume = originalVolume
        self.externalLuminance = externalLuminance
        self.caffeinatePID = caffeinatePID
        self.sleepDisabled = sleepDisabled
        self.lidWatcherPID = lidWatcherPID
        self.activatedAt = activatedAt
        self.summary = summary
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        originalBrightness = try values.decode(Double.self, forKey: .originalBrightness)
        originalVolume = try values.decodeIfPresent(Int.self, forKey: .originalVolume)
        externalLuminance = try values.decodeIfPresent(Int.self, forKey: .externalLuminance)
        caffeinatePID = try values.decode(Int32.self, forKey: .caffeinatePID)
        sleepDisabled = try values.decodeIfPresent(Bool.self, forKey: .sleepDisabled)
        lidWatcherPID = try values.decodeIfPresent(Int32.self, forKey: .lidWatcherPID)
        activatedAt = try values.decode(Date.self, forKey: .activatedAt)
        // try? on purpose: a summary this build cannot read (written by a
        // newer one, or damaged) must never make the state unrestorable
        summary = try? values.decodeIfPresent(SessionSummary.self, forKey: .summary)
    }
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
    public static func saveState(brightness: Double, volume: Int?, externalLuminance: Int?, pid: pid_t, sleepDisabled: Bool, lidWatcherPID: pid_t?, summary: SessionSummary? = nil) -> Bool {
        return save(BlackoutState(
            originalBrightness: brightness,
            originalVolume: volume,
            externalLuminance: externalLuminance,
            caffeinatePID: pid,
            sleepDisabled: sleepDisabled,
            lidWatcherPID: lidWatcherPID,
            activatedAt: Date(),
            summary: summary
        ))
    }

    /// Write a session's state to disk. Returns false on failure.
    public static func save(_ state: BlackoutState) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(state)
            try data.write(to: stateFileURL)
            ChangeNotifier.post()
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
                ChangeNotifier.post()
            }
        } catch {
            print("Error clearing state: \(error)")
        }
    }
}
