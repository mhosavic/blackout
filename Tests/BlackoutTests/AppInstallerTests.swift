import Testing
import Foundation
import BlackoutCore

struct AppInstallerTests {

    @Test func plistNamesTheProgramAndIsInteractive() throws {
        let xml = AppInstaller.launchAgentPlist(
            programPath: "/Users/someone/Applications/Blackout.app/Contents/MacOS/blackout-menu",
            logPath: "/Users/someone/.blackout/daemon.log")
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any])

        // The label is unchanged from the hotkey daemon, so an upgrade
        // replaces the old job instead of leaving it running beside the new
        #expect(plist["Label"] as? String == "com.blackout.daemon")
        #expect(plist["ProgramArguments"] as? [String] == ["/Users/someone/Applications/Blackout.app/Contents/MacOS/blackout-menu"])
        // Background would have launchd throttle the app and every toggle
        // it starts
        #expect(plist["ProcessType"] as? String == "Interactive")
        #expect(plist["RunAtLoad"] as? Bool == true)
        // Quit from the menu exits 0 and must stay quit; a crash must not
        #expect((plist["KeepAlive"] as? [String: Any])?["SuccessfulExit"] as? Bool == false)
        #expect(plist["StandardOutPath"] as? String == "/Users/someone/.blackout/daemon.log")
        #expect(plist["StandardErrorPath"] as? String == "/Users/someone/.blackout/daemon.log")
    }

    /// A path with characters XML reserves must still produce a valid plist
    @Test func plistEscapesThePath() throws {
        let xml = AppInstaller.launchAgentPlist(programPath: "/Users/a&b/<x>/blackout-menu", logPath: "/tmp/log")
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any])
        #expect(plist["ProgramArguments"] as? [String] == ["/Users/a&b/<x>/blackout-menu"])
    }

    @Test func enclosingBundleFindsTheApp() {
        let bundle = AppInstaller.enclosingBundle(ofExecutable: "/repo/.build/Blackout.app/Contents/MacOS/blackout")
        #expect(bundle?.path == "/repo/.build/Blackout.app")
    }

    /// `install` copies the bundle it runs from; run from a bare build
    /// directory there is no bundle, and it has to say so rather than
    /// install half an app
    @Test func enclosingBundleIsNilOutsideABundle() {
        #expect(AppInstaller.enclosingBundle(ofExecutable: "/repo/.build/release/blackout") == nil)
        #expect(AppInstaller.enclosingBundle(ofExecutable: "/Users/someone/bin/blackout") == nil)
        #expect(AppInstaller.enclosingBundle(ofExecutable: "/repo/Blackout.app/Contents/Resources/blackout") == nil)
        #expect(AppInstaller.enclosingBundle(ofExecutable: "/repo/NotAnApp/Contents/MacOS/blackout") == nil)
    }

    // MARK: - File steps

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blackout-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeBundle(at url: URL, marker: String) throws {
        let macOS = url.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try marker.write(to: macOS.appendingPathComponent("blackout"), atomically: true, encoding: .utf8)
    }

    private func marker(in bundle: URL) -> String? {
        try? String(contentsOf: bundle.appendingPathComponent("Contents/MacOS/blackout"), encoding: .utf8)
    }

    @Test func placeBundleReplacesAnExistingInstall() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("build/Blackout.app")
        let destination = dir.appendingPathComponent("Applications/Blackout.app")
        try makeBundle(at: source, marker: "new")
        try makeBundle(at: destination, marker: "old")
        try "stale".write(to: destination.appendingPathComponent("Contents/leftover"), atomically: true, encoding: .utf8)

        try AppInstaller.placeBundle(from: source, to: destination)

        #expect(marker(in: destination) == "new")
        // Replaced, not merged: nothing from the old bundle survives
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("Contents/leftover").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path) == ["Blackout.app"])
        #expect(marker(in: source) == "new")
    }

    @Test func placeBundleCreatesTheApplicationsFolder() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("Blackout.app")
        let destination = dir.appendingPathComponent("Applications/Blackout.app")
        try makeBundle(at: source, marker: "new")

        try AppInstaller.placeBundle(from: source, to: destination)

        #expect(marker(in: destination) == "new")
    }

    /// The copy is the step that can fail (disk full). The working install
    /// must still be there afterwards, or the user has no hotkey and no
    /// command — possibly with blackout on.
    @Test func placeBundleKeepsTheOldInstallWhenTheCopyFails() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("Applications/Blackout.app")
        try makeBundle(at: destination, marker: "old")

        #expect(throws: (any Error).self) {
            try AppInstaller.placeBundle(from: dir.appendingPathComponent("missing/Blackout.app"), to: destination)
        }
        #expect(marker(in: destination) == "old")
    }

    /// Before 2.0 ~/bin/blackout was a copied binary; the upgrade swaps it
    /// for a link without a moment where the command does not exist
    @Test func replaceLinkSwapsARegularFileForALink() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("Blackout.app/Contents/MacOS/blackout")
        let link = dir.appendingPathComponent("bin/blackout")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "old binary".write(to: link, atomically: true, encoding: .utf8)

        try AppInstaller.replaceLink(at: link, pointingTo: target)

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: link.deletingLastPathComponent().path) == ["blackout"])
    }

    @Test func replaceLinkHandlesADanglingLinkAndAMissingFolder() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("Blackout.app/Contents/MacOS/blackout")
        let link = dir.appendingPathComponent("bin/blackout")

        // No ~/bin yet
        try AppInstaller.replaceLink(at: link, pointingTo: dir.appendingPathComponent("gone"))
        // Now a dangling link, which fileExists reports as absent
        try AppInstaller.replaceLink(at: link, pointingTo: target)

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
    }
}
