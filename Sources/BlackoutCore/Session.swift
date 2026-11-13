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
        /// The session was ended by another command while this one was
        /// still starting it
        case cancelled
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
            lockAvailable: system.isLockAvailable(),
            builtinOffAvailable: system.canSwitchDisplaysOff()
        )
        let plan = SessionPlan.make(settings: settings, probe: probe)
        var summary = plan.summary

        // Save current brightness, volume, and external display luminance
        let brightness = system.brightness()
        var volume: Int?
        if plan.muteAudio {
            let audio = system.outputAudio()
            if audio.muted {
                // Muted by the user before the session: that mute is theirs.
                // Saving a volume here would have disable un-mute it, so the
                // session leaves audio alone in both directions.
                summary.audio = .alreadyMuted
            } else {
                volume = audio.volume
            }
        }
        let externalLuminance = plan.dimExternal ? probe.externalLuminance : nil

        guard let caffeinatePID = system.startCaffeinate() else {
            return .failed("Failed to start caffeinate")
        }

        var sleepDisabledByUs = false
        if plan.disableLidSleep {
            sleepDisabledByUs = system.setLidSleepDisabled(true)
            if !sleepDisabledByUs { summary.lidSleep = .setupMissing }
        }

        // The watcher has two jobs: the lid lock, and — when the built-in
        // display is switched off — bringing it back if the monitor is
        // unplugged. Either one is reason enough to run it.
        var turnBuiltinOff = plan.turnBuiltinOff
        var watcherPID: pid_t?
        if plan.armLidLock || turnBuiltinOff {
            watcherPID = system.startWatcher()
            if watcherPID == nil {
                if plan.armLidLock { summary.lidLock = .watcherFailed }
                // Without the watcher nothing would bring the screen back
                // after an unplug, so the built-in is dimmed instead
                if turnBuiltinOff {
                    turnBuiltinOff = false
                    summary.builtin = .offUnavailable
                }
            }
        }
        // nil with the lid shut: there is no built-in to switch off yet,
        // and the watcher does it when the lid opens
        let builtinID = turnBuiltinOff ? system.builtinDisplayID() : nil

        // Save state before changing anything visible; without it the session
        // could never be restored, so undo and bail if the write fails
        var state = BlackoutState(
            originalBrightness: brightness,
            originalVolume: volume,
            externalLuminance: externalLuminance,
            caffeinatePID: caffeinatePID,
            sleepDisabled: sleepDisabledByUs,
            lidWatcherPID: watcherPID,
            activatedAt: Date(),
            summary: summary,
            builtinOff: turnBuiltinOff ? true : nil,
            builtinDisplayID: builtinID,
            lidLockArmed: watcherPID != nil ? plan.armLidLock : nil
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

        // Turning off never waits on the lock for more than its timeout, so
        // if a step below hangs, an `off` can run underneath us and restore
        // everything. Carrying on would then dim and mute with no session
        // and no restore data, so each remaining step first checks that the
        // session is still there.
        var switchedOff: UInt32?
        // An `off` that ran underneath cannot have known about a display
        // switched off after it finished, so it is switched back on here
        func cancelled() -> EnableResult {
            if let switchedOff {
                _ = system.setDisplay(switchedOff, enabled: true)
            }
            return .cancelled
        }

        if !turnBuiltinOff {
            system.setBrightness(0.0)
        } else if let builtinID {
            guard StateManager.hasState() else { return .cancelled }
            if system.setDisplay(builtinID, enabled: false) {
                switchedOff = builtinID
            } else {
                // macOS refused: go dark the old way, and correct the record
                // so the menu does not claim the display is off and a later
                // display change does not try again. Best effort — the
                // restore reads the same either way.
                system.setBrightness(0.0)
                if StateManager.hasState() {
                    state.builtinOff = nil
                    state.summary?.builtin = .offUnavailable
                    _ = StateManager.save(state)
                }
            }
        }
        if externalLuminance != nil {
            guard StateManager.hasState() else { return cancelled() }
            system.setExternalLuminance(0)
        }
        if volume != nil {
            guard StateManager.hasState() else { return cancelled() }
            system.setMuted(true)
        }
        guard StateManager.hasState() else { return cancelled() }
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
        // Second attempt, and the user is told if it fails: once the state
        // is cleared nothing else would ever switch it back on. Not with the
        // lid shut, where staying dark is expected.
        if state.builtinOff == true, let id = state.builtinDisplayID,
           system.builtinDisplayID() == nil, !system.isLidClosed(),
           !system.setDisplay(id, enabled: true) {
            system.notify(.builtinDisplayStuckOff)
        }
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
    private func restoreDisplays(state: BlackoutState, switchBuiltinOn: Bool = true) {
        // Switched off by the session: back on first, or the brightness
        // below has no display to land on
        if switchBuiltinOn, state.builtinOff == true, let id = state.builtinDisplayID, system.builtinDisplayID() == nil {
            _ = system.setDisplay(id, enabled: true)
        }
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
        guard lockIsArmed(state) else { return .keepWatching }
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
            // the one that has to land. A display switched off is left to
            // the open handler too: switching it on waits for a panel that
            // cannot appear with the lid shut, and the lock must not wait.
            restoreDisplays(state: state, switchBuiltinOn: false)
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
        } else if state.builtinOff == true {
            // Same docked lid cycle in built-in-off mode: macOS brings the
            // panel back on open, so it is switched off again
            reconcileBuiltinDisplay()
        } else {
            // Docked lid cycle: macOS re-lights the panel on open, which
            // would leave a bright screen with blackout still on — re-dim
            // so brightness keeps telling the truth
            system.setBrightness(0.0)
        }
        return .keepWatching
    }

    /// The set of displays changed: a monitor plugged or unplugged, the lid
    /// opened, a display switched off. Only matters while the built-in
    /// display is switched off by the session.
    public func handleDisplaysChanged() -> WatcherAction {
        guard let state = StateManager.loadState() else { return .stop }
        if state.builtinOff == true {
            reconcileBuiltinDisplay()
        }
        return .keepWatching
    }

    /// Make the built-in display match what the session wants right now:
    /// off while an external display is in use, on and dimmed while none
    /// is — the Mac must never be left without a screen. Does nothing when
    /// it already matches, so the display change this causes settles
    /// instead of looping.
    ///
    /// Under the session lock, with the state read again inside it: a
    /// `blackout off` finishing in between must not have its restored
    /// display switched off again by a decision made a moment earlier. The
    /// wait is short — this runs on the watcher's only thread, and the lid
    /// and unlock handlers must not queue behind a hung toggle. Giving up
    /// is safe: the next display change tries again.
    private func reconcileBuiltinDisplay() {
        _ = SessionLock.withLock(waitingAtMost: 3) {
            guard var state = StateManager.loadState(), state.builtinOff == true else { return }

            // A state file outlives a crash or a power cut. With no session
            // actually running the display may be brought back, but never
            // switched off or dimmed.
            let running = system.isCaffeinateRunning(pid: state.caffeinatePID)
            // A lock screen is never darkened or moved: the lid-open
            // restore has just lit it
            let locked = system.isScreenLocked()

            guard system.isExternalDisplayOnline() else {
                if system.builtinDisplayID() == nil, !system.isLidClosed(), let id = state.builtinDisplayID {
                    _ = system.setDisplay(id, enabled: true)
                }
                // Blackout is still on, now on a laptop alone: dark, as it
                // would be had the session started undocked
                if running && !locked {
                    system.setBrightness(0.0)
                }
                return
            }

            guard running, !locked else { return }
            // nil: already off, or the lid is shut — nothing to do
            guard let id = system.builtinDisplayID() else { return }
            // Listed by macOS but unreadable: AirPlay, Sidecar, a virtual
            // display, a monitor switched off. Not a screen in use, so the
            // built-in stays on, dark.
            guard system.externalLuminance() != nil else {
                system.setBrightness(0.0)
                return
            }
            if state.builtinDisplayID != id {
                // On disk before the display goes off, or it could never be
                // found again to switch back on
                state.builtinDisplayID = id
                guard StateManager.save(state) else {
                    system.setBrightness(0.0)
                    return
                }
            }
            if !system.setDisplay(id, enabled: false) {
                system.setBrightness(0.0)
            }
        }
    }

    /// Whether the watcher locks on lid close and ends the session on
    /// unlock. A state file without the answer predates the watcher having
    /// any other job: there, a watcher always meant the lock was armed.
    private func lockIsArmed(_ state: BlackoutState) -> Bool {
        return state.lidLockArmed ?? true
    }

    public func handleUnlock(notify: Bool) -> WatcherAction {
        guard let state = StateManager.loadState() else { return .stop }
        // A watcher running only for built-in-off mode behaves as if there
        // were none: with the lock setting off, an unlock ends nothing. The
        // session goes on, so a built-in lit for the lock screen goes back
        // to what the session wants.
        guard lockIsArmed(state) else {
            if state.builtinOff == true {
                reconcileBuiltinDisplay()
            }
            return .keepWatching
        }
        // Authenticating means the owner is back: end the session so the
        // restored brightness keeps telling the truth about blackout.
        // Unconditional on purpose — no display check may ever gate this.
        _ = disable(notify: notify)
        return .stop
    }
}
