import Testing
import BlackoutCore

struct SessionPlanTests {

    /// A laptop on its own: nothing plugged in, nothing pre-disabled
    private let alone = SystemProbe(externalOnline: false, externalLuminance: nil, sleepAlreadyDisabled: false, lockAvailable: true)
    /// Docked to a monitor m1ddc can talk to
    private let docked = SystemProbe(externalOnline: true, externalLuminance: 80, sleepAlreadyDisabled: false, lockAvailable: true)

    private func plan(_ probe: SystemProbe, _ change: (inout Settings) -> Void = { _ in }) -> SessionPlan {
        var settings = Settings()
        change(&settings)
        return SessionPlan.make(settings: settings, probe: probe)
    }

    // MARK: - Audio

    @Test func autoMutesWithoutExternal() {
        let plan = plan(alone)
        #expect(plan.muteAudio)
        #expect(plan.summary.audio == .muted)
    }

    @Test func autoKeepsAudioWithExternal() {
        let plan = plan(docked)
        #expect(!plan.muteAudio)
        #expect(plan.summary.audio == .leftOnExternalDisplay)
    }

    @Test func neverMuteIsBySetting() {
        let plan = plan(alone) { $0.muteAudio = .never }
        #expect(!plan.muteAudio)
        #expect(plan.summary.audio == .leftOnBySetting)
    }

    @Test func alwaysMutesEvenWithExternal() {
        let plan = plan(docked) { $0.muteAudio = .always }
        #expect(plan.muteAudio)
        #expect(plan.summary.audio == .muted)
    }

    // MARK: - External display

    @Test func noExternalIsNone() {
        let plan = plan(alone) { $0.dimExternal = true }
        #expect(!plan.dimExternal)
        #expect(plan.summary.external == .none)
    }

    @Test func externalLeftOnByDefault() {
        let plan = plan(docked)
        #expect(!plan.dimExternal)
        #expect(plan.summary.external == .leftOn)
    }

    @Test func dimsExternalWhenAskedAndLuminanceKnown() {
        let plan = plan(docked) { $0.dimExternal = true }
        #expect(plan.dimExternal)
        #expect(plan.summary.external == .dimmed)
    }

    /// Listed by CoreGraphics but m1ddc gave no reading: a monitor that is
    /// switched off, Sidecar, a virtual display. Treated as absent, so audio
    /// fails toward muted rather than toward playing on a dark machine.
    @Test func unreachableExternalIsTreatedAsAbsent() {
        var probe = docked
        probe.externalLuminance = nil
        let plan = plan(probe) { $0.dimExternal = true }
        #expect(!plan.dimExternal)
        #expect(plan.summary.external == .unreachable)
        #expect(plan.muteAudio)
        #expect(plan.summary.audio == .muted)
    }

    // MARK: - Built-in display

    @Test func builtinIsDimmedByDefault() {
        for probe in [alone, docked] {
            let plan = plan(probe)
            #expect(!plan.turnBuiltinOff)
            #expect(plan.summary.builtin == nil)
        }
    }

    @Test func builtinGoesOffWhenDockedAndAsked() {
        let plan = plan(docked) { $0.builtinOff = true }
        #expect(plan.turnBuiltinOff)
        #expect(plan.summary.builtin == .off)
    }

    /// Switching off the only screen would leave the Mac with none
    @Test func builtinStaysOnWithoutAnExternalInUse() {
        #expect(!plan(alone) { $0.builtinOff = true }.turnBuiltinOff)

        var unreachable = docked
        unreachable.externalLuminance = nil
        #expect(!plan(unreachable) { $0.builtinOff = true }.turnBuiltinOff)
    }

    /// "Dim everything" mode keeps its old behavior: both screens dimmed
    @Test func builtinIsDimmedWhenTheExternalIsDimmedToo() {
        let plan = plan(docked) { $0.builtinOff = true; $0.dimExternal = true }
        #expect(!plan.turnBuiltinOff)
        #expect(plan.summary.builtin == nil)
    }

    @Test func builtinIsDimmedWhenMacOSCannotSwitchItOff() {
        var probe = docked
        probe.builtinOffAvailable = false
        let plan = plan(probe) { $0.builtinOff = true }
        #expect(!plan.turnBuiltinOff)
        #expect(plan.summary.builtin == .offUnavailable)
    }

    // MARK: - Lid sleep

    @Test func lidSleepOffBySetting() {
        let plan = plan(alone) { $0.keepAwakeLidClosed = false }
        #expect(!plan.disableLidSleep)
        #expect(plan.summary.lidSleep == .offBySetting)
    }

    /// The user disabled sleep themselves; taking ownership would make
    /// turning blackout off re-enable it behind their back
    @Test func lidSleepLeftAloneWhenAlreadyDisabled() {
        var probe = alone
        probe.sleepAlreadyDisabled = true
        let plan = plan(probe)
        #expect(!plan.disableLidSleep)
        #expect(plan.summary.lidSleep == .alreadyDisabled)
    }

    @Test func lidSleepAttemptedOtherwise() {
        let plan = plan(alone)
        #expect(plan.disableLidSleep)
        #expect(plan.summary.lidSleep == .disabled)
    }

    // MARK: - Lid lock

    @Test func lockArmedWhenAvailable() {
        // Armed even while docked: whether a given close locks is decided
        // at that moment, not here
        for probe in [alone, docked] {
            let plan = plan(probe)
            #expect(plan.armLidLock)
            #expect(plan.summary.lidLock == .armed)
        }
    }

    @Test func lockOffBySetting() {
        let plan = plan(alone) { $0.lockOnLidClose = false }
        #expect(!plan.armLidLock)
        #expect(plan.summary.lidLock == .offBySetting)
    }

    @Test func lockUnavailableWithoutSymbol() {
        var probe = alone
        probe.lockAvailable = false
        let plan = plan(probe)
        #expect(!plan.armLidLock)
        #expect(plan.summary.lidLock == .unavailable)
    }
}
