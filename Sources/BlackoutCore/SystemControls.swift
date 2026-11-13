import Foundation

public enum NotificationMessage {
    case enabled
    case disabled
    /// Re-enabling sleep failed; the Mac will not sleep until the user acts
    case sleepRestoreFailed
}

/// Everything a session reads from or does to the Mac. The one seam between
/// the session logic and the hardware, so the logic runs in tests against a
/// recording fake instead of a real display, speaker and lid.
public protocol SystemControls {
    func brightness() -> Double
    func setBrightness(_ value: Double)

    func isExternalDisplayOnline() -> Bool
    func externalLuminance() -> Int?
    func setExternalLuminance(_ level: Int)

    func volume() -> Int
    func setVolume(_ level: Int)
    func setMuted(_ muted: Bool)

    func startCaffeinate() -> pid_t?
    func stopCaffeinate(pid: pid_t)
    /// Whether `pid` is still the caffeinate a session started — not merely
    /// alive: after a reboot the number can belong to anything
    func isCaffeinateRunning(pid: pid_t) -> Bool

    func isSleepDisabled() -> Bool
    func setLidSleepDisabled(_ disabled: Bool) -> Bool

    func isLockAvailable() -> Bool
    func lockScreen()
    func startWatcher() -> pid_t?
    func stopWatcher(pid: pid_t)
    func isWatcherRunning(pid: pid_t) -> Bool

    func notify(_ message: NotificationMessage)

    var ownPID: pid_t { get }
}

/// The real Mac
public struct LiveSystem: SystemControls {

    public init() {}

    public func brightness() -> Double { BrightnessController.getBrightness() }
    public func setBrightness(_ value: Double) { BrightnessController.setBrightness(value) }

    public func isExternalDisplayOnline() -> Bool { ExternalDisplayController.isExternalDisplayOnline() }
    public func externalLuminance() -> Int? { ExternalDisplayController.getLuminance() }
    public func setExternalLuminance(_ level: Int) { ExternalDisplayController.setLuminance(level) }

    public func volume() -> Int { AudioController.getVolume() }
    public func setVolume(_ level: Int) { AudioController.setVolume(level) }
    public func setMuted(_ muted: Bool) {
        if muted { AudioController.mute() } else { AudioController.unmute() }
    }

    public func startCaffeinate() -> pid_t? { SleepController.preventSleep() }
    public func stopCaffeinate(pid: pid_t) { SleepController.allowSleep(pid: pid) }
    public func isCaffeinateRunning(pid: pid_t) -> Bool {
        SleepController.processName(pid: pid) == "caffeinate"
    }

    public func isSleepDisabled() -> Bool { SleepController.isSleepDisabled() }
    public func setLidSleepDisabled(_ disabled: Bool) -> Bool {
        disabled ? SleepController.disableLidSleep() : SleepController.restoreLidSleep()
    }

    public func isLockAvailable() -> Bool { LidLockController.isLockAvailable() }
    public func lockScreen() { LidLockController.lockScreen() }
    public func startWatcher() -> pid_t? { LidLockController.startWatcher() }
    public func stopWatcher(pid: pid_t) { LidLockController.stopWatcher(pid: pid) }
    public func isWatcherRunning(pid: pid_t) -> Bool {
        // The watcher is the CLI re-executed as `blackout --lid-watch`
        SleepController.processName(pid: pid) == "blackout"
    }

    public func notify(_ message: NotificationMessage) { NotificationManager.show(message) }

    public var ownPID: pid_t { ProcessInfo.processInfo.processIdentifier }
}
