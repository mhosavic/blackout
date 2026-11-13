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
}
