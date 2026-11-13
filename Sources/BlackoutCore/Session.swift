import Foundation

/// Starting and ending a blackout session, and what the lid watcher does in
/// between. Decides nothing about presentation: callers print or draw from
/// the results.
public struct Session {

    private let system: SystemControls

    public init(system: SystemControls = LiveSystem()) {
        self.system = system
    }

    // MARK: - Enable

    public struct EnableReport {
        public let state: BlackoutState
    }

    public enum EnableResult {
        case enabled(EnableReport)
        case alreadyOn
        /// Another blackout command held the lock past the timeout
        case busy
        case failed(String)
    }

    public func enable(settings: Settings) -> EnableResult {
        return SessionLock.withLock { enableLocked(settings: settings) } ?? .busy
    }

    private func enableLocked(settings: Settings) -> EnableResult {
        // Checked inside the lock: a simultaneous enable that got here first
        // has already started the session
        guard !StateManager.hasState() else { return .alreadyOn }

        // m1ddc is asked only when a display is actually plugged in, and
        // pmset only when lid sleep is ours to manage, so the common toggle
        // spawns nothing it does not need
        let externalOnline = system.isExternalDisplayOnline()
        let probe = SystemProbe(
            externalOnline: externalOnline,
            externalLuminance: externalOnline ? system.externalLuminance() : nil,
            sleepAlreadyDisabled: settings.keepAwakeLidClosed && system.isSleepDisabled(),
            lockAvailable: system.isLockAvailable()
        )
        let plan = SessionPlan.make(settings: settings, probe: probe)
        var summary = plan.summary

        // Save current brightness, volume, and external display luminance
        let brightness = system.brightness()
        let volume = plan.muteAudio ? system.volume() : nil
        let externalLuminance = plan.dimExternal ? probe.externalLuminance : nil

        guard let caffeinatePID = system.startCaffeinate() else {
            return .failed("Failed to start caffeinate")
        }

        var sleepDisabledByUs = false
        if plan.disableLidSleep {
            sleepDisabledByUs = system.setLidSleepDisabled(true)
            if !sleepDisabledByUs { summary.lidSleep = .setupMissing }
        }

        var watcherPID: pid_t?
        if plan.armLidLock {
            watcherPID = system.startWatcher()
            if watcherPID == nil { summary.lidLock = .watcherFailed }
        }

        // Save state before changing anything visible; without it the session
        // could never be restored, so undo and bail if the write fails
        let state = BlackoutState(
            originalBrightness: brightness,
            originalVolume: volume,
            externalLuminance: externalLuminance,
            caffeinatePID: caffeinatePID,
            sleepDisabled: sleepDisabledByUs,
            lidWatcherPID: watcherPID,
            activatedAt: Date(),
            summary: summary
        )
        guard StateManager.save(state) else {
            system.stopCaffeinate(pid: caffeinatePID)
            if let watcherPID {
                system.stopWatcher(pid: watcherPID)
            }
            if sleepDisabledByUs {
                _ = system.setLidSleepDisabled(false)
            }
            return .failed("Failed to save state — blackout not enabled")
        }

        system.setBrightness(0.0)
        if externalLuminance != nil {
            system.setExternalLuminance(0)
        }
        if plan.muteAudio {
            system.setMuted(true)
        }
        if settings.notifications {
            system.notify(.enabled)
        }

        return .enabled(EnableReport(state: state))
    }

    // MARK: - Disable

    public struct DisableReport {
        public let state: BlackoutState
        /// The session's caffeinate was already gone (crash or reboot)
        public let recoveredStaleSession: Bool
        /// Sleep was disabled by the session and could not be re-enabled
        public let lidSleepRestoreFailed: Bool
    }

    public enum DisableResult {
        case disabled(DisableReport)
        case alreadyOff
        /// The state file could not be read; it has been cleared
        case corruptState
    }

    /// End the session. `notify` covers the confirmation only: the warning
    /// that sleep could not be re-enabled is always sent.
    public func disable(notify: Bool) -> DisableResult {
        return SessionLock.withLockOrProceed { disableLocked(notify: notify) }
    }

    private func disableLocked(notify: Bool) -> DisableResult {
        guard StateManager.hasState() else { return .alreadyOff }
        guard let state = StateManager.loadState() else {
            StateManager.clearState()
            return .corruptState
        }

        // Stop caffeinate to allow sleep — unless it already died (crash/reboot),
        // in which case the PID may have been reused by another process
        let caffeinateRunning = system.isCaffeinateRunning(pid: state.caffeinatePID)
        if caffeinateRunning {
            system.stopCaffeinate(pid: state.caffeinatePID)
        }

        // Stop the lid watcher. Skip our own PID: on the unlock path this function
        // runs inside the watcher, and SIGTERMing ourselves here would abandon the
        // restore half-done. A dead or missing PID just means it already exited.
        if let watcherPID = state.lidWatcherPID,
           watcherPID != system.ownPID,
           system.isWatcherRunning(pid: watcherPID) {
            system.stopWatcher(pid: watcherPID)
        }

        // Re-enable lid-close sleep if we disabled it
        var lidSleepRestoreFailed = false
        if state.sleepDisabled == true {
            lidSleepRestoreFailed = !system.setLidSleepDisabled(false)
        }

        restoreDisplays(state: state)
        if let volume = state.originalVolume {
            system.setMuted(false)
            system.setVolume(volume)
        }

        StateManager.clearState()

        if notify {
            system.notify(.disabled)
        }
        if lidSleepRestoreFailed {
            system.notify(.sleepRestoreFailed)
        }

        return .disabled(DisableReport(
            state: state,
            recoveredStaleSession: !caffeinateRunning,
            lidSleepRestoreFailed: lidSleepRestoreFailed
        ))
    }

    /// Bring the panels back to what the user had. Idempotent — disable sets
    /// the same values again — so the watcher can call it on every lid event.
    private func restoreDisplays(state: BlackoutState) {
        system.setBrightness(state.originalBrightness)
        if let externalLuminance = state.externalLuminance {
            system.setExternalLuminance(externalLuminance)
        }
    }

    // MARK: - Lid watcher

    public enum WatcherAction {
        case keepWatching
        /// The session is over; the watcher has nothing left to act on
        case stop
    }

    // Each handler reloads state: if the session ended without the watcher
    // being killed, there is nothing left to act on.

    public func handleLidClose() -> WatcherAction {
        guard let state = StateManager.loadState() else { return .stop }
        // Decided here, not at enable time, so plugging or unplugging a
        // display mid-session changes the outcome — unplugged means the
        // protection comes back, docked means the session stays usable
        let lock = LidLockController.shouldLockOnLidClose(
            externalOnline: system.isExternalDisplayOnline(),
            externalWasDimmed: state.externalLuminance != nil
        )
        if lock {
            // Undo the dim before locking. The panel may already be
            // powering down, so this is best-effort; the open handler is
            // the one that has to land.
            restoreDisplays(state: state)
            system.lockScreen()
        }
        return .keepWatching
    }

    public func handleLidOpen(screenLocked: Bool) -> WatcherAction {
        guard let state = StateManager.loadState() else { return .stop }
        if screenLocked {
            // Without this the lock screen is a black rectangle and the
            // password field cannot be seen
            restoreDisplays(state: state)
        } else {
            // Docked lid cycle: macOS re-lights the panel on open, which
            // would leave a bright screen with blackout still on — re-dim
            // so brightness keeps telling the truth
            system.setBrightness(0.0)
        }
        return .keepWatching
    }

    public func handleUnlock(notify: Bool) -> WatcherAction {
        guard StateManager.loadState() != nil else { return .stop }
        // Authenticating means the owner is back: end the session so the
        // restored brightness keeps telling the truth about blackout.
        // Unconditional on purpose — no display check may ever gate this.
        _ = disable(notify: notify)
        return .stop
    }
}
