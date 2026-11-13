import Foundation

/// The one-time setup each optional behavior depends on. Checked rather
/// than assumed, so a setting that is on but cannot work is said out loud.
public struct Health: Equatable {
    /// The passwordless sudo rule from `blackout setup-lid`
    public var lidSetupInstalled: Bool
    public var m1ddcInstalled: Bool
    public var lockAvailable: Bool

    public init(lidSetupInstalled: Bool, m1ddcInstalled: Bool, lockAvailable: Bool) {
        self.lidSetupInstalled = lidSetupInstalled
        self.m1ddcInstalled = m1ddcInstalled
        self.lockAvailable = lockAvailable
    }

    /// Runs `sudo -n -l`, so not for the main thread of anything with a UI
    public static func check() -> Health {
        return Health(
            lidSetupInstalled: SleepController.isLidSetupInstalled(),
            m1ddcInstalled: ExternalDisplayController.isM1ddcInstalled(),
            lockAvailable: LidLockController.isLockAvailable()
        )
    }
}
