import Foundation

/// What a session decided for each thing it can touch, and why. Saved in the
/// state file so the menu and `blackout status` can explain a running
/// session; never consulted when restoring.
public struct SessionSummary: Codable, Equatable {

    public enum Audio: String, Codable {
        case muted
        /// The user had muted audio themselves before the session started,
        /// so it is theirs: neither muted nor un-muted by blackout
        case alreadyMuted
        case leftOnBySetting
        case leftOnExternalDisplay
    }

    public enum External: String, Codable {
        /// No external display online
        case none
        case dimmed
        case leftOn
        /// Listed by CoreGraphics but m1ddc got no reading from it (switched
        /// off, Sidecar, a virtual display) — treated as absent
        case unreachable
    }

    public enum LidSleep: String, Codable {
        case disabled
        /// Sleep was already disabled system-wide, so it is not ours to restore
        case alreadyDisabled
        case offBySetting
        /// The passwordless sudo rule from `blackout setup-lid` is not installed
        case setupMissing
    }

    public enum LidLock: String, Codable {
        case armed
        case offBySetting
        /// macOS no longer exposes SACLockScreenImmediate
        case unavailable
        case watcherFailed
    }

    public enum Builtin: String, Codable {
        /// Switched off, so the external display is the main one
        case off
        /// Asked to switch it off, but macOS would not; dimmed instead
        case offUnavailable
    }

    public var audio: Audio
    public var external: External
    public var lidSleep: LidSleep
    public var lidLock: LidLock
    /// nil means dimmed, which is all a session did before this existed
    public var builtin: Builtin?

    public init(audio: Audio, external: External, lidSleep: LidSleep, lidLock: LidLock, builtin: Builtin? = nil) {
        self.audio = audio
        self.external = external
        self.lidSleep = lidSleep
        self.lidLock = lidLock
        self.builtin = builtin
    }
}
