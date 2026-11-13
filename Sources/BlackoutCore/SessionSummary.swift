import Foundation

/// What a session decided for each thing it can touch, and why. Saved in the
/// state file so the menu and `blackout status` can explain a running
/// session; never consulted when restoring.
public struct SessionSummary: Codable, Equatable {

    public enum Audio: String, Codable {
        case muted
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

    public var audio: Audio
    public var external: External
    public var lidSleep: LidSleep
    public var lidLock: LidLock

    public init(audio: Audio, external: External, lidSleep: LidSleep, lidLock: LidLock) {
        self.audio = audio
        self.external = external
        self.lidSleep = lidSleep
        self.lidLock = lidLock
    }
}
