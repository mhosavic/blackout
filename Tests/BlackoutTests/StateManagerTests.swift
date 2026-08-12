import Testing
import Foundation
import BlackoutCore

/// Serialized because all tests share StateManager.stateFileURL,
/// which each instance points at its own temporary directory
@Suite(.serialized)
final class StateManagerTests {

    private let tempDir: URL
    private let originalStateFileURL: URL

    init() throws {
        originalStateFileURL = StateManager.stateFileURL
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blackout-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        StateManager.stateFileURL = tempDir.appendingPathComponent("state.json")
    }

    deinit {
        StateManager.stateFileURL = originalStateFileURL
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test func saveAndLoadRoundTrip() {
        let saved = StateManager.saveState(brightness: 0.42, volume: 37, externalLuminance: 80, pid: 12345, sleepDisabled: true, lidWatcherPID: 54321)
        #expect(saved)

        let state = StateManager.loadState()
        #expect(state?.originalBrightness == 0.42)
        #expect(state?.originalVolume == 37)
        #expect(state?.externalLuminance == 80)
        #expect(state?.caffeinatePID == 12345)
        #expect(state?.sleepDisabled == true)
        #expect(state?.lidWatcherPID == 54321)
    }

    @Test func saveWithSkippedFeaturesStoresNils() {
        let saved = StateManager.saveState(brightness: 1.0, volume: nil, externalLuminance: nil, pid: 1, sleepDisabled: false, lidWatcherPID: nil)
        #expect(saved)

        let state = StateManager.loadState()
        #expect(state != nil)
        #expect(state?.originalVolume == nil)
        #expect(state?.externalLuminance == nil)
        #expect(state?.sleepDisabled == false)
        #expect(state?.lidWatcherPID == nil)
    }

    /// State files written before the lid-sleep feature have no sleepDisabled
    /// key and must still decode
    @Test func loadsLegacyStateWithoutSleepDisabledKey() throws {
        let legacyJSON = """
        {
          "originalBrightness" : 0.5,
          "caffeinatePID" : 999,
          "originalVolume" : 25,
          "activatedAt" : "2026-01-15T10:00:00Z"
        }
        """
        try legacyJSON.write(to: StateManager.stateFileURL, atomically: true, encoding: .utf8)

        let state = StateManager.loadState()
        #expect(state?.originalBrightness == 0.5)
        #expect(state?.caffeinatePID == 999)
        #expect(state?.sleepDisabled == nil)
        #expect(state?.externalLuminance == nil)
        #expect(state?.lidWatcherPID == nil)
    }

    @Test func corruptStateFileLoadsAsNilButStillCounts() throws {
        try "not valid json{{{".write(to: StateManager.stateFileURL, atomically: true, encoding: .utf8)

        // hasState must stay true so main.swift can detect and clear it,
        // rather than enabling on top of a possibly-active session
        #expect(StateManager.hasState())
        #expect(StateManager.loadState() == nil)
    }

    @Test func hasStateReflectsFileExistence() {
        #expect(!StateManager.hasState())
        _ = StateManager.saveState(brightness: 0.5, volume: nil, externalLuminance: nil, pid: 1, sleepDisabled: false, lidWatcherPID: nil)
        #expect(StateManager.hasState())
        StateManager.clearState()
        #expect(!StateManager.hasState())
    }

    @Test func clearStateIsIdempotent() {
        StateManager.clearState()
        StateManager.clearState()
        #expect(!StateManager.hasState())
    }

    @Test func saveStateReportsFailure() {
        StateManager.stateFileURL = tempDir
            .appendingPathComponent("missing-dir")
            .appendingPathComponent("state.json")
        let saved = StateManager.saveState(brightness: 0.5, volume: nil, externalLuminance: nil, pid: 1, sleepDisabled: false, lidWatcherPID: nil)
        #expect(!saved)
    }
}
