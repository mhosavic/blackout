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

    /// Reported by a colleague: he keeps his Mac muted, and turning blackout
    /// on and off again un-muted it. A mute that was there before blackout
    /// is the user's, not ours — the session must leave audio alone entirely.
    @Test func aMuteSetBeforeBlackoutSurvivesTheSession() {
        system.mutedValue = true

        #expect(isEnabled(session.enable(settings: settings())))
        let state = StateManager.loadState()
        #expect(state?.originalVolume == nil)
        #expect(state?.summary?.audio == .alreadyMuted)

        guard case .disabled = session.disable(notify: false) else {
            Issue.record("disable should succeed")
            return
        }
        #expect(!system.events.contains { $0.hasPrefix("setMuted") })
        #expect(!system.events.contains { $0.hasPrefix("setVolume") })
    }

    /// Same with the "always mute" setting: already muted is already muted
    @Test func alwaysMuteAlsoLeavesAnExistingMuteAlone() {
        system.mutedValue = true
        system.externalOnline = true
        system.externalLuminanceValue = 80

        #expect(isEnabled(session.enable(settings: settings { $0.muteAudio = .always })))
        _ = session.disable(notify: false)

        #expect(!system.events.contains { $0.hasPrefix("setMuted") })
        #expect(!system.events.contains { $0.hasPrefix("setVolume") })
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

    // MARK: - Built-in display off

    private func enableDockedWithBuiltinOff(_ change: (inout Settings) -> Void = { _ in }) -> Session.EnableResult {
        system.externalOnline = true
        system.externalLuminanceValue = 80
        return session.enable(settings: settings { $0.builtinOff = true; change(&$0) })
    }

    /// Docked with the setting on: the built-in is switched off, not dimmed.
    /// Its ID is on disk before it goes off — afterwards it is no longer
    /// listed, and without the ID it could never be switched back on.
    @Test func enableSwitchesTheBuiltinOffInsteadOfDimming() {
        var idOnDiskWhenSwitchedOff: UInt32?
        system.onSetDisplay = { idOnDiskWhenSwitchedOff = StateManager.loadState()?.builtinDisplayID }

        #expect(isEnabled(enableDockedWithBuiltinOff()))

        #expect(system.events.contains("setDisplay 1 off"))
        #expect(!system.events.contains { $0.hasPrefix("setBrightness") })
        #expect(idOnDiskWhenSwitchedOff == 1)
        let state = StateManager.loadState()
        #expect(state?.builtinOff == true)
        #expect(state?.summary?.builtin == .off)
        #expect(state?.originalBrightness == 0.62)
    }

    /// The call can fail on a macOS that changed it. The session must still
    /// go dark, the old way, and say what happened.
    @Test func enableFallsBackToDimmingWhenTheSwitchFails() {
        system.switchSucceeds = false

        #expect(isEnabled(enableDockedWithBuiltinOff()))

        #expect(system.events.contains("setBrightness 0.0"))
        #expect(StateManager.loadState()?.summary?.builtin == .offUnavailable)
        // No longer in this mode, or a later display change would try again
        #expect(StateManager.loadState()?.builtinOff == nil)
    }

    /// No watcher means nothing would bring the screen back after an
    /// unplug, so the display is dimmed rather than switched off
    @Test func enableDimsInsteadWhenTheWatcherCannotStart() {
        system.watcherPID = nil

        #expect(isEnabled(enableDockedWithBuiltinOff()))

        #expect(!system.events.contains { $0.hasPrefix("setDisplay") })
        #expect(system.events.contains("setBrightness 0.0"))
        let state = StateManager.loadState()
        #expect(state?.builtinOff == nil)
        #expect(state?.summary?.builtin == .offUnavailable)
    }

    /// An `off` ran underneath a slow enable and restored everything. The
    /// display this enable then switched off must come back on: there is no
    /// session left that would ever do it.
    @Test func cancelledEnableSwitchesTheBuiltinBackOn() {
        system.externalOnline = true
        system.externalLuminanceValue = 80
        system.onSetDisplay = { StateManager.clearState() }

        let result = session.enable(settings: settings { $0.builtinOff = true; $0.muteAudio = .always })

        guard case .cancelled = result else {
            Issue.record("enable should report cancelled, got \(result)")
            return
        }
        #expect(system.events.last == "setDisplay 1 on")
        #expect(!StateManager.hasState())
    }

    /// The monitor is unplugged while the built-in is off: without this the
    /// Mac has no screen at all. It comes back on, dimmed — blackout is
    /// still on, as it would be on a laptop alone.
    @Test func unpluggingTheMonitorBringsTheBuiltinBackDimmed() {
        #expect(isEnabled(enableDockedWithBuiltinOff()))
        system.events = []
        system.externalOnline = false

        #expect(session.handleDisplaysChanged() == .keepWatching)
        #expect(system.events == ["setDisplay 1 on", "setBrightness 0.0"])
    }

    @Test func pluggingTheMonitorBackInSwitchesTheBuiltinOffAgain() {
        #expect(isEnabled(enableDockedWithBuiltinOff()))
        system.externalOnline = false
        _ = session.handleDisplaysChanged()
        system.events = []
        system.externalOnline = true

        #expect(session.handleDisplaysChanged() == .keepWatching)
        #expect(system.events == ["probeExternalLuminance", "setDisplay 1 off"])
    }

    /// The approved rule: a lock screen is never left dark. Sequence found
    /// in review — monitor unplugged, lid closed (locks), lid opened: the
    /// open restores brightness, and the display change the lid itself
    /// raises must not dim it again a moment later.
    @Test func aDisplayChangeNeverDarkensTheLockScreen() {
        #expect(isEnabled(enableDockedWithBuiltinOff()))
        system.externalOnline = false
        _ = session.handleDisplaysChanged()
        #expect(session.handleLidClose() == .keepWatching)
        system.screenLocked = true
        system.events = []

        #expect(session.handleLidOpen(screenLocked: true) == .keepWatching)
        #expect(session.handleDisplaysChanged() == .keepWatching)

        #expect(system.events == ["setBrightness 0.62"])
    }

    /// Locked with the monitor still attached: the lock screen needs no
    /// help, and the built-in that the lid-open restore lit is left alone
    @Test func aDisplayChangeWhileLockedDoesNotSwitchTheBuiltinOff() {
        #expect(isEnabled(enableDockedWithBuiltinOff()))
        system.builtinID = 1
        system.screenLocked = true
        system.events = []

        #expect(session.handleDisplaysChanged() == .keepWatching)
        #expect(system.events.isEmpty)
    }

    /// After a crash or power cut the state file outlives the session. A
    /// monitor plugged in then must not switch the screen off for a
    /// blackout that is not running — but a missing screen is still brought
    /// back.
    @Test func aDeadSessionNeverSwitchesTheBuiltinOff() {
        #expect(isEnabled(enableDockedWithBuiltinOff()))
        system.runningCaffeinates = []
        system.builtinID = 1
        system.events = []

        #expect(session.handleDisplaysChanged() == .keepWatching)
        #expect(system.events.isEmpty)

        system.builtinID = nil
        system.externalOnline = false
        #expect(session.handleDisplaysChanged() == .keepWatching)
        // Back on, and not dimmed: no blackout is running
        #expect(system.events == ["setDisplay 1 on"])
    }

    /// AirPlay, Sidecar or a virtual display appearing mid-session is
    /// listed by macOS but is not a monitor in use; switching the built-in
    /// off for it would leave nothing to look at
    @Test func aDisplayThatM1ddcCannotReadDoesNotSwitchTheBuiltinOff() {
        #expect(isEnabled(enableDockedWithBuiltinOff()))
        system.externalOnline = false
        _ = session.handleDisplaysChanged()
        system.events = []
        system.externalOnline = true
        system.externalLuminanceValue = nil

        #expect(session.handleDisplaysChanged() == .keepWatching)
        #expect(system.events == ["probeExternalLuminance", "setBrightness 0.0"])
    }

    /// With the lid shut the built-in cannot appear; trying to switch it on
    /// on every display change would only wait and repeat
    @Test func lidShutUndockedDoesNotTryToSwitchTheBuiltinOn() {
        #expect(isEnabled(enableDockedWithBuiltinOff()))
        system.externalOnline = false
        system.lidClosed = true
        system.events = []

        #expect(session.handleDisplaysChanged() == .keepWatching)
        #expect(!system.events.contains { $0.hasPrefix("setDisplay") })
    }

    /// Closing the lid has to lock at once. Switching the display on first
    /// would wait for a panel that cannot appear with the lid shut.
    @Test func lidCloseLocksWithoutSwitchingTheDisplay() {
        #expect(isEnabled(enableDockedWithBuiltinOff()))
        system.externalOnline = false
        system.events = []

        #expect(session.handleLidClose() == .keepWatching)
        #expect(system.events == ["setBrightness 0.62", "lockScreen"])
    }

    @Test func disableWarnsWhenTheBuiltinCannotBeSwitchedBackOn() {
        #expect(isEnabled(enableDockedWithBuiltinOff()))
        system.switchSucceeds = false
        system.events = []

        _ = session.disable(notify: false)
        #expect(system.events.contains("notify builtinDisplayStuckOff"))
    }

    /// With the lid shut the display staying dark is expected, not a fault
    @Test func disableDoesNotWarnWithTheLidShut() {
        #expect(isEnabled(enableDockedWithBuiltinOff()))
        system.switchSucceeds = false
        system.lidClosed = true
        system.events = []

        _ = session.disable(notify: false)
        #expect(!system.events.contains("notify builtinDisplayStuckOff"))
    }

    /// Lock setting off, but macOS locked by itself and the lid-open restore
    /// lit the built-in for the lock screen. After the unlock the session
    /// goes on, so the display has to go back to what the session wants.
    @Test func unlockWithoutTheLockArmedPutsTheBuiltinBackOff() {
        #expect(isEnabled(enableDockedWithBuiltinOff { $0.lockOnLidClose = false }))
        system.screenLocked = true
        _ = session.handleLidOpen(screenLocked: true)
        system.screenLocked = false
        system.events = []

        #expect(session.handleUnlock(notify: true) == .keepWatching)
        #expect(system.events == ["probeExternalLuminance", "setDisplay 1 off"])
        #expect(StateManager.hasState())
    }

    /// Switching the display off itself raises a display-change event; that
    /// must settle, not loop
    @Test func aDisplayChangeWithNothingToCorrectDoesNothing() {
        #expect(isEnabled(enableDockedWithBuiltinOff()))
        system.events = []

        #expect(session.handleDisplaysChanged() == .keepWatching)
        #expect(system.events.isEmpty)
    }

    @Test func displayChangesAreIgnoredOutsideThisMode() {
        saveState()
        system.externalOnline = true

        #expect(session.handleDisplaysChanged() == .keepWatching)
        #expect(system.events.isEmpty)
    }

    /// Blackout turned on with the lid already shut: there was no built-in
    /// to switch off then. When the lid opens it is, and its ID is recorded.
    @Test func lidOpenedWhileDockedSwitchesTheBuiltinOff() {
        system.builtinID = nil
        #expect(isEnabled(enableDockedWithBuiltinOff()))
        #expect(StateManager.loadState()?.builtinDisplayID == nil)
        system.events = []
        system.builtinID = 1

        #expect(session.handleLidOpen(screenLocked: false) == .keepWatching)
        #expect(system.events == ["probeExternalLuminance", "setDisplay 1 off"])
        #expect(StateManager.loadState()?.builtinDisplayID == 1)
    }

    /// A lock screen on a display that is switched off cannot be unlocked
    @Test func lidOpenedOntoLockScreenSwitchesTheBuiltinOn() {
        #expect(isEnabled(enableDockedWithBuiltinOff()))
        system.events = []

        #expect(session.handleLidOpen(screenLocked: true) == .keepWatching)
        #expect(system.events == ["setDisplay 1 on", "setBrightness 0.62"])
    }

    /// With the lock setting off, a watcher that exists only for this mode
    /// must behave as if there were none: no lock, and an unlock (after a
    /// manual ⌃⌘Q) does not end the session
    @Test func watcherWithoutTheLockArmedNeitherLocksNorEndsTheSession() {
        #expect(isEnabled(enableDockedWithBuiltinOff { $0.lockOnLidClose = false }))
        system.externalOnline = false
        system.events = []

        #expect(session.handleLidClose() == .keepWatching)
        #expect(!system.events.contains("lockScreen"))
        #expect(session.handleUnlock(notify: true) == .keepWatching)
        #expect(StateManager.hasState())
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
