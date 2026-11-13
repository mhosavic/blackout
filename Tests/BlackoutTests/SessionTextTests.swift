import Testing
import Foundation
import BlackoutCore

struct SessionTextTests {

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func state(
        volume: Int? = 35,
        externalLuminance: Int? = nil,
        sleepDisabled: Bool? = true,
        watcher: Int32? = 2002,
        summary: SessionSummary?
    ) -> BlackoutState {
        BlackoutState(
            originalBrightness: 0.62, originalVolume: volume, externalLuminance: externalLuminance,
            caffeinatePID: 1001, sleepDisabled: sleepDisabled, lidWatcherPID: watcher,
            activatedAt: date("2026-11-13T14:36:19Z"), summary: summary)
    }

    private func lines(
        audio: SessionSummary.Audio = .muted,
        external: SessionSummary.External = .none,
        lidSleep: SessionSummary.LidSleep = .disabled,
        lidLock: SessionSummary.LidLock = .armed,
        externalLuminance: Int? = nil,
        externalOnline: Bool = false
    ) -> [String] {
        let summary = SessionSummary(audio: audio, external: external, lidSleep: lidSleep, lidLock: lidLock)
        return SessionText.sessionLines(
            state: state(externalLuminance: externalLuminance, summary: summary), externalOnline: externalOnline)
    }

    @Test func laptopAlone() {
        #expect(lines() == [
            "Built-in display dimmed (was 62%)",
            "Audio muted (was 35%)",
            "Awake with the lid closed",
            "Locks when the lid closes"
        ])
    }

    @Test func externalLines() {
        #expect(lines(external: .dimmed, externalLuminance: 40, externalOnline: true)[1] == "External display dimmed (was 40%)")
        #expect(lines(external: .leftOn, externalOnline: true)[1] == "External display left on")
        #expect(lines(external: .unreachable, externalOnline: true)[1] == "External display not reachable by m1ddc (treated as absent)")
    }

    @Test func audioLines() {
        #expect(lines(audio: .leftOnBySetting).contains("Audio left on (setting)"))
        #expect(lines(audio: .leftOnExternalDisplay).contains("Audio left on (external display connected)"))
    }

    @Test func lidSleepLines() {
        #expect(lines(lidSleep: .alreadyDisabled).contains("Awake with the lid closed (sleep was already disabled system-wide)"))
        #expect(lines(lidSleep: .offBySetting).contains("Sleeps when the lid closes (setting)"))
        #expect(lines(lidSleep: .setupMissing).contains("Sleeps when the lid closes (run \"blackout setup-lid\" once)"))
    }

    @Test func lidLockLines() {
        #expect(lines(lidLock: .offBySetting).last == "Does not lock when the lid closes (setting)")
        #expect(lines(lidLock: .unavailable).last == "Cannot lock when the lid closes (macOS lock call missing)")
        #expect(lines(lidLock: .watcherFailed).last == "Cannot lock when the lid closes (watcher failed to start)")
    }

    /// The lock is decided when the lid closes, from the displays online at
    /// that moment — so the line has to follow the displays online now, not
    /// what was plugged in when the session started
    @Test func armedLockLineFollowsTheLiveDisplays() {
        #expect(lines(external: .leftOn, externalOnline: true).last == "Won't lock while the external display is on")
        // The monitor was unplugged since: the protection is back
        #expect(lines(external: .leftOn, externalOnline: false).last == "Locks when the lid closes")
        // Dimmed too: no usable screen is left, so it locks
        #expect(lines(external: .dimmed, externalLuminance: 40, externalOnline: true).last == "Locks when the lid closes")
        // Plugged in after the session started
        #expect(lines(external: .none, externalOnline: true).last == "Won't lock while the external display is on")
    }

    /// A session started by a version that wrote no summary
    @Test func legacyStateLines() {
        let muted = SessionText.sessionLines(state: state(summary: nil), externalOnline: false)
        #expect(muted == [
            "Built-in display dimmed (was 62%)",
            "Audio muted (was 35%)",
            "Awake with the lid closed",
            "Locks when the lid closes"
        ])

        let bare = SessionText.sessionLines(
            state: state(volume: nil, sleepDisabled: nil, watcher: nil, summary: nil), externalOnline: false)
        #expect(bare == ["Built-in display dimmed (was 62%)", "Audio left on"])

        let dimmed = SessionText.sessionLines(
            state: state(volume: nil, externalLuminance: 40, sleepDisabled: false, watcher: nil, summary: nil), externalOnline: true)
        #expect(dimmed == ["Built-in display dimmed (was 62%)", "External display dimmed (was 40%)", "Audio left on"])
    }

    @Test func headlineOnOffAndUnreadable() {
        let on = state(summary: nil)
        #expect(SessionText.headline(state: nil, stateFileExists: false, now: date("2026-11-13T15:00:00Z"), calendar: utc) == "Blackout is off")
        #expect(SessionText.headline(state: on, stateFileExists: true, now: date("2026-11-13T15:00:00Z"), calendar: utc) == "Blackout is on · since 14:36")
        // Left on overnight: the time alone would mislead
        #expect(SessionText.headline(state: on, stateFileExists: true, now: date("2026-11-14T09:00:00Z"), calendar: utc) == "Blackout is on · since Nov 13, 14:36")
        // A state file that cannot be read still means a session to end
        #expect(SessionText.headline(state: nil, stateFileExists: true, now: date("2026-11-13T15:00:00Z"), calendar: utc) == "Blackout is on (state file unreadable)")
    }

    @Test func settingTitlesAndValues() {
        var settings = Settings()
        #expect(SessionText.title(forSetting: "mute") == "Mute audio")
        #expect(SessionText.title(forSetting: "dim-external") == "Dim the external display too")
        #expect(SessionText.title(forSetting: "lid") == "Keep awake with the lid closed")
        #expect(SessionText.title(forSetting: "lock") == "Lock when the lid closes")
        #expect(SessionText.title(forSetting: "notifications") == "Show notifications")
        #expect(SessionText.label(for: MutePolicy.auto) == "Only without an external display")
        #expect(SessionText.label(for: MutePolicy.always) == "Always")
        #expect(SessionText.label(for: MutePolicy.never) == "Never")

        settings.muteAudio = .never
        let lines = SessionText.settingsLines(settings)
        #expect(lines.count == Settings.keys.count)
        #expect(lines[0].hasPrefix("mute"))
        #expect(lines[0].contains("never"))
        #expect(lines[0].hasSuffix("Mute audio (auto|always|never)"))
        #expect(lines[1].hasSuffix("Dim the external display too (on|off)"))
    }
}
