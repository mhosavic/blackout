import Testing
import Foundation
import BlackoutCore

extension FileBackedTests {
@Suite final class SessionTests {

    private let tempDir: URL
    private let originalStateFileURL: URL
    private let originalLockFileURL: URL
    private let system = FakeSystem()
    private var session: Session { Session(system: system) }

    init() throws {
        originalStateFileURL = StateManager.stateFileURL
        originalLockFileURL = SessionLock.fileURL
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blackout-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        StateManager.stateFileURL = tempDir.appendingPathComponent("state.json")
        SessionLock.fileURL = tempDir.appendingPathComponent("lock")
    }

    deinit {
        StateManager.stateFileURL = originalStateFileURL
        SessionLock.fileURL = originalLockFileURL
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func settings(_ change: (inout Settings) -> Void = { _ in }) -> Settings {
        var settings = Settings()
        change(&settings)
        return settings
    }

    /// Put a session on disk as an earlier enable would have
    private func saveState(volume: Int? = 35, externalLuminance: Int? = nil, sleepDisabled: Bool = true, watcher: pid_t? = 2002) {
        _ = StateManager.saveState(brightness: 0.62, volume: volume, externalLuminance: externalLuminance, pid: 1001, sleepDisabled: sleepDisabled, lidWatcherPID: watcher)
    }

    private func isEnabled(_ result: Session.EnableResult) -> Bool {
        if case .enabled = result { return true }
        return false
    }

    // MARK: - Enable

    /// A session without saved state can never be restored, so the state must
    /// be on disk before the first thing the user can see changes
    @Test func enableSavesStateBeforeAnyVisibleChange() {
        var stateExistedWhenScreenDimmed = false
        system.onSetBrightness = { stateExistedWhenScreenDimmed = StateManager.hasState() }

        #expect(isEnabled(session.enable(settings: settings())))
        #expect(stateExistedWhenScreenDimmed)
    }

    @Test func enableFollowsThePlanOnALaptopAlone() {
        #expect(isEnabled(session.enable(settings: settings())))

        #expect(system.events == [
            "startCaffeinate",
            "setLidSleepDisabled true",
            "startWatcher",
            "setBrightness 0.0",
            "setMuted true",
            "notify enabled"
        ])

        let state = StateManager.loadState()
        #expect(state?.originalBrightness == 0.62)
        #expect(state?.originalVolume == 35)
        #expect(state?.externalLuminance == nil)
        #expect(state?.caffeinatePID == 1001)
        #expect(state?.sleepDisabled == true)
        #expect(state?.lidWatcherPID == 2002)
        #expect(state?.summary == SessionSummary(audio: .muted, external: .none, lidSleep: .disabled, lidLock: .armed))
    }

    /// Nothing plugged in: m1ddc is not even asked, so a slow or hung DDC
    /// call cannot delay the common toggle
    @Test func enableSkipsTheDDCProbeWhenNothingIsPluggedIn() {
        system.externalLuminanceValue = 80

        #expect(isEnabled(session.enable(settings: settings())))

        #expect(!system.events.contains("probeExternalLuminance"))
        #expect(StateManager.loadState()?.summary?.external == SessionSummary.External.none)
    }

    /// Docked: the monitor is the working screen. It is not dimmed and audio
    /// stays on.
    @Test func enableLeavesExternalAndAudioWhenDocked() {
        system.externalOnline = true
        system.externalLuminanceValue = 80

        #expect(isEnabled(session.enable(settings: settings())))

        #expect(!system.events.contains { $0.hasPrefix("setExternalLuminance") })
        #expect(!system.events.contains { $0.hasPrefix("setMuted") })
        let state = StateManager.loadState()
        #expect(state?.originalVolume == nil)
        #expect(state?.externalLuminance == nil)
        #expect(state?.summary?.audio == .leftOnExternalDisplay)
        #expect(state?.summary?.external == .leftOn)
    }

    @Test func enableDimsExternalWhenAsked() {
        system.externalOnline = true
        system.externalLuminanceValue = 80

        #expect(isEnabled(session.enable(settings: settings { $0.dimExternal = true })))

        #expect(system.events.contains("setExternalLuminance 0"))
        #expect(StateManager.loadState()?.externalLuminance == 80)
        #expect(StateManager.loadState()?.summary?.external == .dimmed)
    }

    /// pmset refused (no sudo rule): the session still starts, records that
    /// sleep is not ours to restore, and says why
    @Test func enableRecordsSetupMissingWhenPmsetFails() {
        system.lidSleepSucceeds = false

        #expect(isEnabled(session.enable(settings: settings())))

        let state = StateManager.loadState()
        #expect(state?.sleepDisabled == false)
        #expect(state?.summary?.lidSleep == .setupMissing)
    }

    @Test func enableRecordsWatcherFailed() {
        system.watcherPID = nil

        #expect(isEnabled(session.enable(settings: settings())))

        let state = StateManager.loadState()
        #expect(state?.lidWatcherPID == nil)
        #expect(state?.summary?.lidLock == .watcherFailed)
    }

    @Test func enableSkipsWhatTheSettingsTurnOff() {
        let result = session.enable(settings: settings {
            $0.muteAudio = .never
            $0.keepAwakeLidClosed = false
            $0.lockOnLidClose = false
            $0.notifications = false
        })

        #expect(isEnabled(result))
        #expect(system.events == ["startCaffeinate", "setBrightness 0.0"])
        #expect(StateManager.loadState()?.summary == SessionSummary(audio: .leftOnBySetting, external: .none, lidSleep: .offBySetting, lidLock: .offBySetting))
    }

    @Test func enableRollsBackWhenStateCannotBeSaved() {
        StateManager.stateFileURL = tempDir.appendingPathComponent("missing-dir/state.json")

        guard case .failed = session.enable(settings: settings()) else {
            Issue.record("enable should fail when the state cannot be saved")
            return
        }

        #expect(system.events == [
            "startCaffeinate",
            "setLidSleepDisabled true",
            "startWatcher",
            "stopCaffeinate 1001",
            "stopWatcher 2002",
            "setLidSleepDisabled false"
        ])
    }

    /// The second of two simultaneous toggles lands here once the first has
    /// finished: it must not start a second caffeinate
    @Test func enableWhenAlreadyOnDoesNothing() {
        saveState()

        guard case .alreadyOn = session.enable(settings: settings()) else {
            Issue.record("enable should report alreadyOn")
            return
        }
        #expect(system.events.isEmpty)
    }

    /// Two hotkey presses landing together: both decide "turn on", and the
    /// real lock has to make the second one find the first one's session
    @Test func simultaneousEnablesStartOneCaffeinate() {
        system.caffeinateDelay = 0.2
        let settings = settings()
        let session = self.session
        let group = DispatchGroup()
        let results = ResultBox()

        for _ in 0..<2 {
            DispatchQueue.global().async(group: group) {
                results.add(session.enable(settings: settings))
            }
        }
        group.wait()

        #expect(system.events.filter { $0 == "startCaffeinate" }.count == 1)
        #expect(results.enabledCount == 1)
        #expect(results.alreadyOnCount == 1)
    }

    /// Another blackout command holds the lock and never lets go. Turning on
    /// must give up rather than risk a second caffeinate.
    @Test func enableGivesUpWhileAnotherCommandHoldsTheLock() throws {
        let originalTimeout = SessionLock.timeout
        SessionLock.timeout = 0.2
        defer { SessionLock.timeout = originalTimeout }
        let fd = open(SessionLock.fileURL.path, O_CREAT | O_RDWR, 0o644)
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        defer { flock(fd, LOCK_UN); close(fd) }

        guard case .busy = session.enable(settings: settings()) else {
            Issue.record("enable should report busy")
            return
        }
        #expect(system.events.isEmpty)
    }

    /// The same hang must not keep the user from getting their screen back
    @Test func disableProceedsWhileAnotherCommandHoldsTheLock() throws {
        saveState()
        let originalTimeout = SessionLock.timeout
        SessionLock.timeout = 0.2
        defer { SessionLock.timeout = originalTimeout }
        let fd = open(SessionLock.fileURL.path, O_CREAT | O_RDWR, 0o644)
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        defer { flock(fd, LOCK_UN); close(fd) }

        guard case .disabled = session.disable(notify: false) else {
            Issue.record("disable should go ahead")
            return
        }
        #expect(system.events.contains("setBrightness 0.62"))
    }

    /// A hung step can keep enable going past the point where `off` stops
    /// waiting for the lock and restores everything. Enable must then stop,
    /// not carry on dimming and muting a session that no longer exists and
    /// has no restore data.
    @Test func enableStopsIfTheSessionWasEndedUnderneathIt() {
        system.externalOnline = true
        system.externalLuminanceValue = 80
        system.onSetBrightness = { StateManager.clearState() }

        let result = session.enable(settings: settings { $0.dimExternal = true; $0.muteAudio = .always })

        guard case .cancelled = result else {
            Issue.record("enable should report cancelled, got \(result)")
            return
        }
        #expect(!system.events.contains { $0.hasPrefix("setExternalLuminance") })
        #expect(!system.events.contains { $0.hasPrefix("setMuted") })
        #expect(!system.events.contains { $0.hasPrefix("notify") })
    }

    @Test func enableFailsWithoutCaffeinate() {
        system.caffeinatePID = nil

        guard case .failed = session.enable(settings: settings()) else {
            Issue.record("enable should fail without caffeinate")
            return
        }
        #expect(system.events == ["startCaffeinate"])
        #expect(!StateManager.hasState())
    }

    // MARK: - Disable

    @Test func disableRestoresEverythingTheStateNames() {
        saveState(externalLuminance: 80)

        guard case .disabled(let report) = session.disable(notify: true) else {
            Issue.record("disable should succeed")
            return
        }

        #expect(system.events == [
            "stopCaffeinate 1001",
            "stopWatcher 2002",
            "setLidSleepDisabled false",
            "setBrightness 0.62",
            "setExternalLuminance 80",
            "setMuted false",
            "setVolume 35",
            "notify disabled"
        ])
        #expect(!report.recoveredStaleSession)
        #expect(!report.lidSleepRestoreFailed)
        #expect(!StateManager.hasState())
    }

    /// A session started by the previous version has no summary; turning it
    /// off with this version must restore it all the same
    @Test func disableRestoresFromLegacyStateWithoutSummary() throws {
        let legacy = """
        {
          "originalBrightness": 0.4,
          "originalVolume": 20,
          "caffeinatePID": 1001,
          "sleepDisabled": true,
          "lidWatcherPID": 2002,
          "activatedAt": "2026-11-13T19:36:19Z"
        }
        """
        try legacy.write(to: StateManager.stateFileURL, atomically: true, encoding: .utf8)

        guard case .disabled = session.disable(notify: false) else {
            Issue.record("disable should succeed")
            return
        }

        #expect(system.events == [
            "stopCaffeinate 1001",
            "stopWatcher 2002",
            "setLidSleepDisabled false",
            "setBrightness 0.4",
            "setMuted false",
            "setVolume 20"
        ])
        #expect(!StateManager.hasState())
    }

    @Test func disableLeavesAloneWhatTheSessionDidNotTouch() {
        saveState(volume: nil, externalLuminance: nil, sleepDisabled: false, watcher: nil)

        guard case .disabled = session.disable(notify: false) else {
            Issue.record("disable should succeed")
            return
        }
        #expect(system.events == ["stopCaffeinate 1001", "setBrightness 0.62"])
    }

    /// After a crash or reboot the saved PIDs may belong to unrelated
    /// processes; they must not be signalled
    @Test func disableDoesNotSignalProcessesThatAreNotOurs() {
        saveState()
        system.runningCaffeinates = []
        system.runningWatchers = []

        guard case .disabled(let report) = session.disable(notify: false) else {
            Issue.record("disable should succeed")
            return
        }
        #expect(report.recoveredStaleSession)
        #expect(!system.events.contains { $0.hasPrefix("stopCaffeinate") })
        #expect(!system.events.contains { $0.hasPrefix("stopWatcher") })
        #expect(system.events.contains("setBrightness 0.62"))
    }

    /// On the unlock path disable runs inside the watcher; signalling itself
    /// would abandon the restore half done
    @Test func disableDoesNotSignalItsOwnPID() {
        saveState()
        system.ownPID = 2002

        guard case .disabled = session.disable(notify: false) else {
            Issue.record("disable should succeed")
            return
        }
        #expect(!system.events.contains { $0.hasPrefix("stopWatcher") })
        #expect(system.events.contains("setBrightness 0.62"))
    }

    /// The one warning that ignores the notifications setting: a Mac that
    /// silently never sleeps again is worse than an unwanted banner
    @Test func disableReportsSleepRestoreFailureEvenWithNotificationsOff() {
        saveState()
        system.lidSleepSucceeds = false

        guard case .disabled(let report) = session.disable(notify: false) else {
            Issue.record("disable should succeed")
            return
        }
        #expect(report.lidSleepRestoreFailed)
        #expect(system.events.contains("notify sleepRestoreFailed"))
        #expect(!system.events.contains("notify disabled"))
    }

    @Test func disableWhenOffDoesNothing() {
        guard case .alreadyOff = session.disable(notify: true) else {
            Issue.record("disable should report alreadyOff")
            return
        }
        #expect(system.events.isEmpty)
    }

    @Test func disableClearsACorruptStateFile() throws {
        try "not json".write(to: StateManager.stateFileURL, atomically: true, encoding: .utf8)

        guard case .corruptState = session.disable(notify: true) else {
            Issue.record("disable should report corruptState")
            return
        }
        #expect(system.events.isEmpty)
        #expect(!StateManager.hasState())
    }

    // MARK: - Lid watcher

    @Test func lidCloseRestoresAndLocksWithoutExternal() {
        saveState()

        #expect(session.handleLidClose() == .keepWatching)
        #expect(system.events == ["setBrightness 0.62", "lockScreen"])
    }

    @Test func lidCloseDoesNothingWhileDocked() {
        saveState()
        system.externalOnline = true

        #expect(session.handleLidClose() == .keepWatching)
        #expect(system.events.isEmpty)
    }

    /// With the external dimmed too there is no usable screen left, so the
    /// lid close locks even though a display is attached
    @Test func lidCloseLocksWhenExternalWasDimmed() {
        saveState(externalLuminance: 80)
        system.externalOnline = true

        #expect(session.handleLidClose() == .keepWatching)
        #expect(system.events == ["setBrightness 0.62", "setExternalLuminance 80", "lockScreen"])
    }

    /// Without this the lock screen is a black rectangle
    @Test func lidOpenOnLockScreenRestoresDisplays() {
        saveState(externalLuminance: 80)

        #expect(session.handleLidOpen(screenLocked: true) == .keepWatching)
        #expect(system.events == ["setBrightness 0.62", "setExternalLuminance 80"])
    }

    @Test func lidOpenUnlockedRedims() {
        saveState()

        #expect(session.handleLidOpen(screenLocked: false) == .keepWatching)
        #expect(system.events == ["setBrightness 0.0"])
    }

    /// Unconditional on purpose: no display check may ever gate this
    @Test func unlockAlwaysEndsTheSession() {
        saveState()
        system.externalOnline = true
        system.ownPID = 2002

        #expect(session.handleUnlock(notify: true) == .stop)
        #expect(system.events.contains("setBrightness 0.62"))
        #expect(system.events.contains("notify disabled"))
        #expect(!StateManager.hasState())
    }

    @Test func handlersStopWhenTheSessionIsGone() {
        #expect(session.handleLidClose() == .stop)
        #expect(session.handleLidOpen(screenLocked: true) == .stop)
        #expect(session.handleLidOpen(screenLocked: false) == .stop)
        #expect(session.handleUnlock(notify: true) == .stop)
        #expect(system.events.isEmpty)
    }
}
}

/// Collects results from two threads
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Session.EnableResult] = []

    func add(_ result: Session.EnableResult) {
        lock.lock(); defer { lock.unlock() }
        results.append(result)
    }

    var enabledCount: Int {
        results.filter { if case .enabled = $0 { return true } else { return false } }.count
    }

    var alreadyOnCount: Int {
        results.filter { if case .alreadyOn = $0 { return true } else { return false } }.count
    }
}
