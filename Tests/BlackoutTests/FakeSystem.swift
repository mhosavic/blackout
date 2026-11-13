import Foundation
import BlackoutCore

/// Stands in for the Mac: answers probes from settable values and records
/// every effect, in order, so a test can assert both what a session did and
/// what it left alone.
final class FakeSystem: SystemControls {

    var events: [String] = []

    // Answers
    var brightnessValue = 0.62
    var externalOnline = false
    var externalLuminanceValue: Int?
    var volumeValue = 35
    var caffeinatePID: pid_t? = 1001
    var watcherPID: pid_t? = 2002
    var runningCaffeinates: Set<pid_t> = [1001]
    var runningWatchers: Set<pid_t> = [2002]
    var sleepDisabled = false
    var lidSleepSucceeds = true
    var lockAvailable = true
    var ownPID: pid_t = 9999
    /// How long startCaffeinate takes, to hold a window open for a second caller
    var caffeinateDelay: TimeInterval = 0

    /// Runs inside setBrightness, for asserting what is already on disk by
    /// the time the screen changes
    var onSetBrightness: (() -> Void)?

    func brightness() -> Double { brightnessValue }
    func setBrightness(_ value: Double) {
        onSetBrightness?()
        events.append("setBrightness \(value)")
    }

    func isExternalDisplayOnline() -> Bool { externalOnline }
    func externalLuminance() -> Int? {
        events.append("probeExternalLuminance")
        return externalLuminanceValue
    }
    func setExternalLuminance(_ level: Int) { events.append("setExternalLuminance \(level)") }

    func volume() -> Int { volumeValue }
    func setVolume(_ level: Int) { events.append("setVolume \(level)") }
    func setMuted(_ muted: Bool) { events.append("setMuted \(muted)") }

    func startCaffeinate() -> pid_t? {
        events.append("startCaffeinate")
        if caffeinateDelay > 0 { Thread.sleep(forTimeInterval: caffeinateDelay) }
        return caffeinatePID
    }
    func stopCaffeinate(pid: pid_t) { events.append("stopCaffeinate \(pid)") }
    func isCaffeinateRunning(pid: pid_t) -> Bool { runningCaffeinates.contains(pid) }

    func isSleepDisabled() -> Bool { sleepDisabled }
    func setLidSleepDisabled(_ disabled: Bool) -> Bool {
        events.append("setLidSleepDisabled \(disabled)")
        return lidSleepSucceeds
    }

    func isLockAvailable() -> Bool { lockAvailable }
    func lockScreen() { events.append("lockScreen") }
    func startWatcher() -> pid_t? {
        events.append("startWatcher")
        return watcherPID
    }
    func stopWatcher(pid: pid_t) { events.append("stopWatcher \(pid)") }
    func isWatcherRunning(pid: pid_t) -> Bool { runningWatchers.contains(pid) }

    func notify(_ message: NotificationMessage) { events.append("notify \(message)") }
}
