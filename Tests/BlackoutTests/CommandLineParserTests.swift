import Testing
import BlackoutCore

struct CommandLineParserTests {

    private func parse(_ arguments: String...) -> Command? {
        try? CommandLineParser.parse(arguments).get()
    }

    private func error(_ arguments: String...) -> String? {
        if case .failure(let error) = CommandLineParser.parse(arguments) { return error.message }
        return nil
    }

    private func overrides(_ change: (inout Overrides) -> Void) -> Overrides {
        var overrides = Overrides()
        change(&overrides)
        return overrides
    }

    @Test func noArgumentsToggles() {
        #expect(parse() == .toggle(Overrides()))
    }

    @Test func onOffToggleWords() {
        #expect(parse("toggle") == .toggle(Overrides()))
        #expect(parse("on") == .on(Overrides()))
        #expect(parse("off") == .off)
        #expect(parse("status") == .status)
        #expect(parse("install") == .install)
        #expect(parse("uninstall") == .uninstall)
        #expect(parse("setup-lid") == .setupLid)
        #expect(parse("help") == .help)
    }

    /// Every option can be forced either way for one run, whatever the
    /// saved settings say
    @Test func overridesBothDirections() {
        #expect(parse("-e") == .toggle(overrides { $0.dimExternal = true }))
        #expect(parse("--dim-external") == .toggle(overrides { $0.dimExternal = true }))
        #expect(parse("--no-dim-external") == .toggle(overrides { $0.dimExternal = false }))
        #expect(parse("--mute") == .toggle(overrides { $0.mute = true }))
        #expect(parse("-m") == .toggle(overrides { $0.mute = false }))
        #expect(parse("--no-mute") == .toggle(overrides { $0.mute = false }))
        #expect(parse("--lid") == .toggle(overrides { $0.lid = true }))
        #expect(parse("-l") == .toggle(overrides { $0.lid = false }))
        #expect(parse("--no-lid") == .toggle(overrides { $0.lid = false }))
        #expect(parse("--lock") == .toggle(overrides { $0.lock = true }))
        #expect(parse("-k") == .toggle(overrides { $0.lock = false }))
        #expect(parse("--no-lock") == .toggle(overrides { $0.lock = false }))
    }

    @Test func overridesCombineWithOnInAnyOrder() {
        let expected = Command.on(overrides { $0.dimExternal = true; $0.lock = false })
        #expect(parse("on", "-e", "--no-lock") == expected)
        #expect(parse("-e", "on", "-k") == expected)
    }

    @Test func overridesApplyOnTopOfSettings() {
        var saved = Settings()
        saved.muteAudio = .never
        saved.lockOnLidClose = false

        let applied = overrides { $0.mute = true; $0.dimExternal = true; $0.lid = false }.applied(to: saved)

        #expect(applied.muteAudio == .always)
        #expect(applied.dimExternal == true)
        #expect(applied.keepAwakeLidClosed == false)
        // Not overridden: the saved value stands
        #expect(applied.lockOnLidClose == false)
        #expect(Overrides().applied(to: saved) == saved)
        #expect(overrides { $0.mute = false }.applied(to: Settings()).muteAudio == .never)
    }

    /// The spellings from before the commands existed; scripts and muscle
    /// memory still use them
    @Test func legacySpellings() {
        #expect(parse("--install") == .install)
        #expect(parse("--uninstall") == .uninstall)
        #expect(parse("--status") == .status)
        #expect(parse("--setup-lid") == .setupLid)
        #expect(parse("--help") == .help)
        #expect(parse("-h") == .help)
        #expect(parse("--lid-watch") == .lidWatch)
    }

    @Test func configShowAndSet() {
        #expect(parse("config") == .configShow)
        #expect(parse("config", "mute", "never") == .configSet(key: "mute", value: "never"))
        // "on" and "off" are commands everywhere else; after a config key
        // they are that key's value
        #expect(parse("config", "lock", "off") == .configSet(key: "lock", value: "off"))
        #expect(parse("config", "notifications", "on") == .configSet(key: "notifications", value: "on"))
    }

    @Test func hotkeyCommand() {
        #expect(parse("hotkey") == .hotkey(reset: false))
        #expect(parse("hotkey", "default") == .hotkey(reset: true))
        #expect(error("hotkey", "cmd-b") != nil)
        #expect(error("hotkey", "default", "extra") != nil)
        #expect(error("hotkey", "-e") != nil)
    }

    @Test func configNeedsKeyAndValue() {
        #expect(error("config", "mute") != nil)
        #expect(error("config", "mute", "never", "extra") != nil)
    }

    /// Before this, a typo such as `blackout --staus` toggled blackout
    @Test func unknownArgumentIsAnError() {
        #expect(error("--staus")?.contains("--staus") == true)
        #expect(error("on", "now") != nil)
        #expect(error("-x") != nil)
    }

    @Test func overridesWithOffAreAnError() {
        #expect(error("off", "-e") != nil)
        #expect(error("status", "--no-mute") != nil)
        #expect(error("config", "--lock") != nil)
    }

    @Test func twoCommandsAreAnError() {
        #expect(error("on", "off") != nil)
        #expect(error("status", "--install") != nil)
    }

    @Test func bothFormsOfOneOptionAreAnError() {
        #expect(error("--mute", "--no-mute") != nil)
        #expect(error("-e", "--no-dim-external") != nil)
        // The same form twice is harmless
        #expect(parse("-e", "--dim-external") == .toggle(overrides { $0.dimExternal = true }))
    }
}
