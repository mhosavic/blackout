import Foundation

/// A release version such as 2.1: numbers separated by dots, compared
/// number by number so 2.10 comes after 2.9, and 2.1 equals 2.1.0
public struct Version: Comparable, CustomStringConvertible {
    public let numbers: [Int]

    /// Accepts the tag form too ("v2.1"). Anything else — a suffix, an
    /// empty part, a space — is not a version.
    public init?(_ text: String) {
        let digits = text.hasPrefix("v") ? text.dropFirst() : Substring(text)
        var numbers: [Int] = []
        for part in digits.split(separator: ".", omittingEmptySubsequences: false) {
            guard !part.isEmpty, part.allSatisfy({ "0123456789".contains($0) }), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        guard !numbers.isEmpty else { return nil }
        self.numbers = numbers
    }

    public var description: String {
        numbers.map(String.init).joined(separator: ".")
    }

    /// Both lists padded with zeros to the same length
    private static func padded(_ a: Version, _ b: Version) -> ([Int], [Int]) {
        let count = max(a.numbers.count, b.numbers.count)
        return (a.numbers + Array(repeating: 0, count: count - a.numbers.count),
                b.numbers + Array(repeating: 0, count: count - b.numbers.count))
    }

    public static func == (a: Version, b: Version) -> Bool {
        let (x, y) = padded(a, b)
        return x == y
    }

    public static func < (a: Version, b: Version) -> Bool {
        let (x, y) = padded(a, b)
        return x.lexicographicallyPrecedes(y)
    }
}

/// A published release: its version and where its Blackout.zip is
public struct Release: Equatable {
    public let version: Version
    public let downloadURL: URL

    public init(version: Version, downloadURL: URL) {
        self.version = version
        self.downloadURL = downloadURL
    }
}

/// The answer of an update check
public enum UpdateCheck: Equatable {
    case upToDate
    case available(Release)
}

/// What the menu shows about updates
public enum UpdateState: Equatable {
    /// Not checked yet, or every check so far failed
    case unknown
    case upToDate
    case available(Version)
    /// Downloading, or the installer is running
    case installing(Version)
}

/// Why an update could not be checked or installed, in words for the menu
/// and the terminal
public struct UpdateError: Error, Equatable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Finds, downloads and unpacks new releases. Installing is left to the
/// new release's own `blackout install` — the install `make install` runs —
/// so an update and a manual install can never do different things.
public enum Updater {

    /// The name every release's zip carries, so the stable link
    /// releases/latest/download/Blackout.zip always serves the newest
    public static let assetName = "Blackout.zip"

    /// Info.plist key holding the URL of GitHub's "latest release" answer
    public static let feedKey = "BlackoutReleaseFeed"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()

    // MARK: - The running app

    /// The Blackout.app this process runs from, or nil for a bare build.
    /// Symlinks resolved: through ~/bin/blackout the path says nothing.
    public static func runningApp() -> URL? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        return AppInstaller.enclosingBundle(ofExecutable: executable.path)
    }

    public static func version(ofApp app: URL) -> Version? {
        (info(ofApp: app)?["CFBundleShortVersionString"] as? String).flatMap { Version($0) }
    }

    public static func feed(ofApp app: URL) -> URL? {
        (info(ofApp: app)?[feedKey] as? String).flatMap { URL(string: $0) }
    }

    private static func info(ofApp app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    // MARK: - Checking

    /// Read GitHub's answer for the latest release
    public static func latestRelease(fromJSON data: Data) throws -> Release {
        guard let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = release["tag_name"] as? String else {
            throw UpdateError("The release server did not describe a release")
        }
        guard let version = Version(tag) else {
            throw UpdateError("The latest release is tagged \"\(tag)\", which is not a version number")
        }
        let assets = release["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { $0["name"] as? String == assetName }),
              let link = asset["browser_download_url"] as? String,
              let downloadURL = URL(string: link) else {
            throw UpdateError("Release \(version) has no \(assetName)")
        }
        // HTTPS only; a file link serves local testing
        guard let scheme = downloadURL.scheme?.lowercased(), ["https", "file"].contains(scheme) else {
            throw UpdateError("Release \(version) links its \(assetName) over \(downloadURL.scheme ?? "no protocol"), not HTTPS")
        }
        return Release(version: version, downloadURL: downloadURL)
    }

    /// Ask the feed for the latest release. A release older than `current`
    /// (a local build ahead of the last release) is never offered.
    public static func check(feed: URL, current: Version) throws -> UpdateCheck {
        var request = URLRequest(url: feed)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Blackout-updater", forHTTPHeaderField: "User-Agent")

        let outcome = Outcome<Data>()
        session.dataTask(with: request) { data, response, error in
            outcome.finish {
                if let error {
                    throw UpdateError("Could not reach \(feed.host ?? "the release server"): \(error.localizedDescription)")
                }
                try checkStatus(response, notFound: "No release of Blackout has been published yet")
                return data ?? Data()
            }
        }.resume()

        let release = try latestRelease(fromJSON: outcome.wait())
        return release.version > current ? .available(release) : .upToDate
    }

    /// Turn an HTTP failure into words. File URLs (tests) have no status.
    private static func checkStatus(_ response: URLResponse?, notFound: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300:
            return
        case 404:
            throw UpdateError(notFound)
        case 403, 429:
            throw UpdateError("GitHub is limiting requests from this network; try again later")
        default:
            throw UpdateError("The release server answered HTTP \(http.statusCode)")
        }
    }

    // MARK: - Downloading

    /// Download `release` into `folder`, emptied first, and unpack it.
    /// Returns the unpacked Blackout.app, checked by `unpack`.
    public static func download(_ release: Release, into folder: URL) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw UpdateError("Could not create \(folder.path): \(error.localizedDescription)")
        }
        let zip = folder.appendingPathComponent(assetName)

        var request = URLRequest(url: release.downloadURL)
        request.setValue("Blackout-updater", forHTTPHeaderField: "User-Agent")

        let outcome = Outcome<Void>()
        session.downloadTask(with: request) { location, response, error in
            // The downloaded file is deleted when this returns: move it now
            outcome.finish {
                if let error {
                    throw UpdateError("The download failed: \(error.localizedDescription)")
                }
                try checkStatus(response, notFound: "Release \(release.version) has no \(assetName)")
                guard let location else { throw UpdateError("The download failed") }
                do {
                    try FileManager.default.moveItem(at: location, to: zip)
                } catch {
                    throw UpdateError("Could not save the download: \(error.localizedDescription)")
                }
            }
        }.resume()
        try outcome.wait()

        return try unpack(zip, into: folder, expecting: release.version)
    }

    /// Unzip `zip` into `folder` and check the Blackout.app inside: both
    /// programs present, the version the release announced, and a valid
    /// signature — a truncated or altered bundle fails the last check.
    public static func unpack(_ zip: URL, into folder: URL, expecting version: Version) throws -> URL {
        let fm = FileManager.default
        let app = folder.appendingPathComponent("Blackout.app")
        // Left by an earlier attempt; must not pass for the new app
        try? fm.removeItem(at: app)

        guard Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path]) == 0 else {
            throw UpdateError("The download is not a valid zip")
        }
        let programs = ["blackout", "blackout-menu"].map { app.appendingPathComponent("Contents/MacOS/\($0)").path }
        guard programs.allSatisfy({ fm.isExecutableFile(atPath: $0) }) else {
            throw UpdateError("The download does not contain Blackout.app")
        }
        guard let found = Updater.version(ofApp: app), found == version else {
            let found = Updater.version(ofApp: app).map { "\($0)" } ?? "no version"
            throw UpdateError("The download holds Blackout \(found), not \(version)")
        }
        // A download made by this app is not quarantined, but a zip fetched
        // with a browser is, and Gatekeeper would then refuse to start it.
        // Exit status ignored: xattr fails harmlessly when there is none.
        Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        guard Shell.run("/usr/bin/codesign", ["--verify", "--strict", app.path]) == 0 else {
            throw UpdateError("The downloaded app does not match its signature")
        }
        return app
    }

    // MARK: - Installing

    private static func installer(in app: URL) -> String {
        app.appendingPathComponent("Contents/MacOS/blackout").path
    }

    /// Run the unpacked app's `blackout install` attached to this terminal,
    /// so its progress shows. Returns its exit status.
    public static func installInForeground(_ app: URL) -> Int32? {
        Shell.runInteractive(installer(in: app), ["install"])
    }

    /// Start the unpacked app's `blackout install` and return its PID
    /// without waiting. Its output is appended to `log`. It runs in a
    /// session of its own because it stops the menu bar app first, and
    /// launchd kills a stopped job's process group along with it.
    public static func startInstall(_ app: URL, log: URL) -> pid_t? {
        Shell.spawnDetached(installer(in: app), ["install"], output: log)
    }

    /// Wait for an installer started with `startInstall`; its exit status
    public static func waitForInstall(_ pid: pid_t) -> Int32 {
        Shell.waitForExit(pid)
    }
}

/// Hands the result of a URLSession callback to the thread waiting for it
private final class Outcome<Value>: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var result: Result<Value, Error> = .failure(UpdateError("No answer"))

    func finish(_ body: () throws -> Value) {
        result = Result(catching: body)
        done.signal()
    }

    func wait() throws -> Value {
        done.wait()
        return try result.get()
    }
}
