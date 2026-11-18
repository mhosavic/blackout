import Testing
import Foundation
import BlackoutCore

struct VersionTests {

    @Test func parsesNumbersWithOrWithoutTheTagPrefix() {
        #expect(Version("2.1")?.description == "2.1")
        #expect(Version("v2.10")?.description == "2.10")
        #expect(Version("3")?.description == "3")
    }

    /// A pre-release or a typo in a tag must not be taken for a version:
    /// the updater would otherwise offer it, or compare it wrongly
    @Test func rejectsAnythingButDottedNumbers() {
        for text in ["", "v", "2.", ".2", "2..1", "2.1-beta", "abc", "2.x", " 2.1", "-1"] {
            #expect(Version(text) == nil, "\(text) should not parse")
        }
    }

    /// Number by number, not as text: 2.10 comes after 2.9
    @Test func comparesNumberByNumber() throws {
        let v = { (text: String) throws -> Version in try #require(Version(text)) }
        #expect(try v("2.10") > v("2.9"))
        #expect(try v("3") > v("2.99"))
        #expect(try v("2.1") < v("2.1.1"))
        #expect(try v("2.1") == v("2.1.0"))
        #expect(try !(v("2.1") < v("2.1.0")))
    }
}

/// Everything here touches files or runs ditto and codesign; nothing
/// touches the network or the installed app
struct UpdaterTests {

    private let fm = FileManager.default

    private func makeTempDir() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("blackout-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func releaseJSON(tag: String, assets: [String: String]) -> Data {
        let assetList = assets.map { ["name": $0.key, "browser_download_url": $0.value] }
        return try! JSONSerialization.data(withJSONObject: [
            "tag_name": tag,
            "html_url": "https://github.com/example/blackout/releases/tag/\(tag)",
            "assets": assetList
        ])
    }

    /// A Blackout.app with real (copied) executables, ad-hoc signed like
    /// `make bundle` signs it, so codesign can verify it
    private func makeApp(in dir: URL, version: String) throws -> URL {
        let app = dir.appendingPathComponent("Blackout.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        for name in ["blackout", "blackout-menu"] {
            try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent(name))
        }
        let info: [String: Any] = [
            "CFBundleExecutable": "blackout-menu",
            "CFBundleIdentifier": "com.blackout.app",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "BlackoutReleaseFeed": "https://api.github.com/repos/example/blackout/releases/latest"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        #expect(run("/usr/bin/codesign", ["--force", "--sign", "-", app.path]) == 0)
        return app
    }

    private func zip(_ item: URL, to zip: URL) {
        #expect(run("/usr/bin/ditto", ["-c", "-k", "--keepParent", item.path, zip.path]) == 0)
    }

    @discardableResult
    private func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: - Reading a release

    @Test func readsTheVersionAndTheZipOfARelease() throws {
        let json = releaseJSON(tag: "v2.2", assets: [
            "Blackout.zip": "https://example.com/Blackout.zip",
            "notes.txt": "https://example.com/notes.txt"
        ])
        let release = try Updater.latestRelease(fromJSON: json)
        #expect(release.version == Version("2.2"))
        #expect(release.downloadURL == URL(string: "https://example.com/Blackout.zip"))
    }

    @Test func aReleaseWithoutTheZipIsAnError() {
        let json = releaseJSON(tag: "v2.2", assets: ["Blackout-2.2.zip": "https://example.com/x.zip"])
        #expect(throws: UpdateError.self) { try Updater.latestRelease(fromJSON: json) }
    }

    /// The zip is fetched over HTTPS only; a plain or odd link in the
    /// answer is refused rather than followed
    @Test func aZipLinkThatIsNotHTTPSIsAnError() {
        for link in ["http://example.com/Blackout.zip", "ftp://example.com/Blackout.zip", "Blackout.zip"] {
            let json = releaseJSON(tag: "v2.2", assets: ["Blackout.zip": link])
            #expect(throws: UpdateError.self, "\(link) should be refused") { try Updater.latestRelease(fromJSON: json) }
        }
    }

    @Test func aTagThatIsNotAVersionIsAnError() {
        let json = releaseJSON(tag: "nightly", assets: ["Blackout.zip": "https://example.com/Blackout.zip"])
        #expect(throws: UpdateError.self) { try Updater.latestRelease(fromJSON: json) }
    }

    @Test func somethingOtherThanAReleaseIsAnError() {
        #expect(throws: UpdateError.self) { try Updater.latestRelease(fromJSON: Data("<html>".utf8)) }
        #expect(throws: UpdateError.self) { try Updater.latestRelease(fromJSON: Data(#"{"message":"Not Found"}"#.utf8)) }
    }

    // MARK: - Checking

    @Test func checkComparesTheLatestReleaseWithTheRunningVersion() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let feed = dir.appendingPathComponent("latest.json")
        try releaseJSON(tag: "v2.2", assets: ["Blackout.zip": "https://example.com/Blackout.zip"]).write(to: feed)

        let v21 = try #require(Version("2.1")), v22 = try #require(Version("2.2")), v23 = try #require(Version("2.3"))
        let zipURL = try #require(URL(string: "https://example.com/Blackout.zip"))

        #expect(try Updater.check(feed: feed, current: v21) == .available(Release(version: v22, downloadURL: zipURL)))
        #expect(try Updater.check(feed: feed, current: v22) == .upToDate)
        // Running a build newer than the latest release (a local build)
        // must never offer a downgrade
        #expect(try Updater.check(feed: feed, current: v23) == .upToDate)
    }

    @Test func checkFailsWhenTheFeedCannotBeRead() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/blackout-feed.json")
        let v21 = try #require(Version("2.1"))
        #expect(throws: UpdateError.self) { try Updater.check(feed: missing, current: v21) }
    }

    // MARK: - Downloading and unpacking

    @Test func downloadUnpacksTheAppOfTheRelease() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let built = dir.appendingPathComponent("built")
        try fm.createDirectory(at: built, withIntermediateDirectories: true)
        let zipURL = dir.appendingPathComponent("Blackout.zip")
        zip(try makeApp(in: built, version: "2.2"), to: zipURL)

        let folder = dir.appendingPathComponent("update")
        // Left over from an earlier attempt: must not be mistaken for the new app
        try fm.createDirectory(at: folder.appendingPathComponent("Blackout.app"), withIntermediateDirectories: true)

        let v22 = try #require(Version("2.2"))
        let app = try Updater.download(Release(version: v22, downloadURL: zipURL), into: folder)
        #expect(app.path == folder.appendingPathComponent("Blackout.app").path)
        #expect(Updater.version(ofApp: app) == Version("2.2"))
        #expect(fm.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/blackout").path))
    }

    /// The release said 2.3 but the zip holds 2.2: installing it would
    /// offer the same update again forever
    @Test func unpackRejectsAnAppOfAnotherVersion() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let zipURL = dir.appendingPathComponent("Blackout.zip")
        zip(try makeApp(in: dir, version: "2.2"), to: zipURL)

        let v23 = try #require(Version("2.3"))
        #expect(throws: UpdateError.self) {
            try Updater.unpack(zipURL, into: dir.appendingPathComponent("out"), expecting: v23)
        }
    }

    @Test func unpackRejectsAZipWithoutTheApp() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let other = dir.appendingPathComponent("Other")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: other.appendingPathComponent("file"))
        let zipURL = dir.appendingPathComponent("Blackout.zip")
        zip(other, to: zipURL)

        let v22 = try #require(Version("2.2"))
        #expect(throws: UpdateError.self) {
            try Updater.unpack(zipURL, into: dir.appendingPathComponent("out"), expecting: v22)
        }
    }

    @Test func unpackRejectsSomethingThatIsNotAZip() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let zipURL = dir.appendingPathComponent("Blackout.zip")
        try Data("<html>Not Found</html>".utf8).write(to: zipURL)

        let v22 = try #require(Version("2.2"))
        #expect(throws: UpdateError.self) {
            try Updater.unpack(zipURL, into: dir.appendingPathComponent("out"), expecting: v22)
        }
    }

    /// A file changed after signing: the bundle is not the one that was
    /// built, so it must not be installed
    @Test func unpackRejectsAnAppAlteredAfterSigning() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let app = try makeApp(in: dir, version: "2.2")
        try Data("added later".utf8).write(to: app.appendingPathComponent("Contents/Resources/extra"))
        let zipURL = dir.appendingPathComponent("Blackout.zip")
        zip(app, to: zipURL)

        let v22 = try #require(Version("2.2"))
        #expect(throws: UpdateError.self) {
            try Updater.unpack(zipURL, into: dir.appendingPathComponent("out"), expecting: v22)
        }
    }

    // MARK: - The running app

    @Test func readsTheVersionAndFeedOfAnApp() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let app = try makeApp(in: dir, version: "2.4")
        #expect(Updater.version(ofApp: app) == Version("2.4"))
        #expect(Updater.feed(ofApp: app) == URL(string: "https://api.github.com/repos/example/blackout/releases/latest"))
        #expect(Updater.version(ofApp: dir) == nil)
        #expect(Updater.feed(ofApp: dir) == nil)
    }

    /// The real Info.plist must carry what the updater reads, or every
    /// installed copy would be stuck on its version
    @Test func theShippedInfoPlistNamesAVersionAndTheReleaseFeed() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repo.appendingPathComponent("Resources/Info.plist"))
        let info = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(Version(info["CFBundleShortVersionString"] as? String ?? "") != nil)
        #expect(info["BlackoutReleaseFeed"] as? String == "https://api.github.com/repos/mhosavic/blackout/releases/latest")
    }
}
