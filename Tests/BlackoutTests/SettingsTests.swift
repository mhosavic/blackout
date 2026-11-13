import Testing
import Foundation
import BlackoutCore

extension FileBackedTests {
@Suite final class SettingsTests {

    private let tempDir: URL
    private let originalFileURL: URL

    init() throws {
        originalFileURL = Settings.fileURL
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blackout-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // One level down, so saving also has to create the directory
        Settings.fileURL = tempDir.appendingPathComponent("dot-blackout/config.json")
    }

    deinit {
        Settings.fileURL = originalFileURL
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ json: String) throws {
        try FileManager.default.createDirectory(
            at: Settings.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: Settings.fileURL, atomically: true, encoding: .utf8)
    }

    /// The defaults are a promise: an upgrade must not change what the
    /// hotkey does for someone who never opens the settings
    @Test func defaultsMatchTodaysBehavior() {
        let settings = Settings()
        #expect(settings.muteAudio == .auto)
        #expect(settings.dimExternal == false)
        #expect(settings.keepAwakeLidClosed == true)
        #expect(settings.lockOnLidClose == true)
        #expect(settings.notifications == true)
    }

    @Test func missingFileLoadsDefaults() {
        #expect(Settings.load() == Settings())
    }

    @Test func roundTrip() {
        var settings = Settings()
        settings.muteAudio = .never
        settings.dimExternal = true
        settings.keepAwakeLidClosed = false
        settings.lockOnLidClose = false
        settings.notifications = false
        #expect(settings.save())
        #expect(Settings.load() == settings)
    }

    @Test func corruptFileLoadsDefaultsAndIsNotRewritten() throws {
        try write("not json")
        #expect(Settings.load() == Settings())
        #expect(try String(contentsOf: Settings.fileURL, encoding: .utf8) == "not json")
    }

    @Test func invalidValueFallsBackToDefaultForThatKeyOnly() throws {
        try write(#"{"muteAudio":"loud","dimExternal":true,"lockOnLidClose":"yes"}"#)
        let settings = Settings.load()
        #expect(settings.muteAudio == .auto)
        #expect(settings.dimExternal == true)
        #expect(settings.lockOnLidClose == true)
    }

    @Test func setParsesEveryKey() {
        var settings = Settings()
        // Collected first: #expect cannot wrap a mutating call
        let accepted = [
            settings.set(key: "mute", value: "never"),
            settings.set(key: "dim-external", value: "on"),
            settings.set(key: "lid", value: "off"),
            settings.set(key: "lock", value: "off"),
            settings.set(key: "notifications", value: "off")
        ]
        #expect(accepted == [true, true, true, true, true])

        #expect(settings.muteAudio == .never)
        #expect(settings.dimExternal == true)
        #expect(settings.keepAwakeLidClosed == false)
        #expect(settings.lockOnLidClose == false)
        #expect(settings.notifications == false)

        let acceptedAlways = settings.set(key: "mute", value: "always")
        #expect(acceptedAlways)
        #expect(settings.muteAudio == .always)
    }

    @Test func setRejectsUnknownKeyAndBadValue() {
        var settings = Settings()
        let accepted = [
            settings.set(key: "volume", value: "on"),
            settings.set(key: "lid", value: "maybe"),
            settings.set(key: "mute", value: "on")
        ]
        #expect(accepted == [false, false, false])
        #expect(settings == Settings())
    }

    @Test func valueForKeyReadsBackWhatSetAccepts() {
        var settings = Settings()
        for key in Settings.keys {
            let value = settings.value(forKey: key)
            #expect(value != nil)
            let accepted = settings.set(key: key, value: value ?? "")
            #expect(accepted)
        }
        #expect(settings == Settings())
        #expect(settings.value(forKey: "volume") == nil)
    }
}
}
