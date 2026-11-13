import Foundation

/// What the machine looks like at the moment a session starts
public struct SystemProbe: Equatable {
    /// CoreGraphics presence — true even when m1ddc cannot reach the display
    public var externalOnline: Bool
    /// m1ddc's reading; nil when nothing is online, m1ddc is not installed,
    /// or the display did not answer
    public var externalLuminance: Int?
    public var sleepAlreadyDisabled: Bool
    public var lockAvailable: Bool
    /// Whether this macOS can switch a display off
    public var builtinOffAvailable: Bool

    public init(externalOnline: Bool, externalLuminance: Int?, sleepAlreadyDisabled: Bool, lockAvailable: Bool, builtinOffAvailable: Bool = true) {
        self.externalOnline = externalOnline
        self.externalLuminance = externalLuminance
        self.sleepAlreadyDisabled = sleepAlreadyDisabled
        self.lockAvailable = lockAvailable
        self.builtinOffAvailable = builtinOffAvailable
    }
}

/// The decisions for one session, made from the settings and the probe
/// before anything is touched. Pure, so every rule can be tested without
/// a display, a speaker or a lid.
public struct SessionPlan: Equatable {

    public let muteAudio: Bool
    public let dimExternal: Bool
    public let disableLidSleep: Bool
    public let armLidLock: Bool
    /// Switch the built-in display off instead of dimming it
    public let turnBuiltinOff: Bool
    /// The outcome if every step succeeds; carrying it out can still
    /// downgrade lidSleep (setup missing) and lidLock (watcher failed)
    public let summary: SessionSummary

    public static func make(settings: Settings, probe: SystemProbe) -> SessionPlan {
        // A monitor counts only if m1ddc can read it: one that is merely
        // listed may be switched off, and assuming it is in use would leave
        // audio playing on a machine nobody is watching
        let externalPresent = probe.externalOnline && probe.externalLuminance != nil

        let audio: SessionSummary.Audio
        switch settings.muteAudio {
        case .always: audio = .muted
        case .never: audio = .leftOnBySetting
        case .auto: audio = externalPresent ? .leftOnExternalDisplay : .muted
        }

        let external: SessionSummary.External
        if !probe.externalOnline {
            external = .none
        } else if !externalPresent {
            external = .unreachable
        } else {
            external = settings.dimExternal ? .dimmed : .leftOn
        }

        let lidSleep: SessionSummary.LidSleep
        if !settings.keepAwakeLidClosed {
            lidSleep = .offBySetting
        } else if probe.sleepAlreadyDisabled {
            lidSleep = .alreadyDisabled
        } else {
            lidSleep = .disabled
        }

        let lidLock: SessionSummary.LidLock
        if !settings.lockOnLidClose {
            lidLock = .offBySetting
        } else {
            lidLock = probe.lockAvailable ? .armed : .unavailable
        }

        // Only with an external display left on: it is the screen that
        // takes over. With nothing else in use the built-in is the last
        // screen, and in "dim everything" mode nothing is meant to stay lit.
        var builtin: SessionSummary.Builtin?
        if settings.builtinOff && external == .leftOn {
            builtin = probe.builtinOffAvailable ? .off : .offUnavailable
        }

        return SessionPlan(
            muteAudio: audio == .muted,
            dimExternal: external == .dimmed,
            disableLidSleep: lidSleep == .disabled,
            armLidLock: lidLock == .armed,
            turnBuiltinOff: builtin == .off,
            summary: SessionSummary(audio: audio, external: external, lidSleep: lidSleep, lidLock: lidLock, builtin: builtin)
        )
    }
}
