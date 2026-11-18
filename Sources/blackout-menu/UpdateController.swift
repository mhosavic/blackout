import AppKit
import BlackoutCore

/// Finds and installs new releases. Checks once a day on its own; the menu
/// asks for a check or an install. The install is the new release's own
/// `blackout install`, which stops this app and starts the new one.
final class UpdateController {

    /// What the menu shows. Touched on the main thread only, like the rest.
    private(set) var state: UpdateState = .unknown
    /// nil when not running from a Blackout.app with a version and a feed
    /// (a bare development build): nothing to check against
    let version: Version?
    private let feed: URL?

    private var available: Release?
    private var lastAnswer: Date?
    private var checking = false
    /// "Check for Updates…" clicked while the daily check was running:
    /// that check's answer is shown when it lands
    private var manualCheckWaiting = false
    private var timer: Timer?

    private static let checkInterval: TimeInterval = 24 * 60 * 60

    init() {
        let app = Updater.runningApp()
        version = app.flatMap { Updater.version(ofApp: $0) }
        feed = app.flatMap { Updater.feed(ofApp: $0) }
        guard let version, feed != nil else {
            Logger.info("No version or release feed in the app bundle: update checks are off")
            return
        }
        Logger.info("Version \(version)")

        // Hourly, checking once a day has passed since the last answer: a
        // check that failed (offline at login) is retried within the hour,
        // and a Mac that slept through the day checks soon after waking.
        // The first one waits a minute, for the network after a login.
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            self?.checkIfDue()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.checkIfDue()
        }
    }

    private var isInstalling: Bool {
        if case .installing = state { return true }
        return false
    }

    private func checkIfDue() {
        if let lastAnswer, Date().timeIntervalSince(lastAnswer) < Self.checkInterval { return }
        check(manual: false)
    }

    // MARK: - Checking

    /// `manual` is a click on "Check for Updates…": that one says what it
    /// found, the daily check only updates the menu
    func check(manual: Bool) {
        guard let version, let feed, !isInstalling else { return }
        guard !checking else {
            manualCheckWaiting = manualCheckWaiting || manual
            return
        }
        checking = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try Updater.check(feed: feed, current: version) }
            DispatchQueue.main.async {
                self?.checked(result, manual: manual)
            }
        }
    }

    private func checked(_ result: Result<UpdateCheck, Error>, manual: Bool) {
        checking = false
        let manual = manual || manualCheckWaiting
        manualCheckWaiting = false
        guard let version, !isInstalling else { return }

        switch result {
        case .success(.upToDate):
            lastAnswer = Date()
            available = nil
            state = .upToDate
            Logger.info("Update check: \(version) is the latest release")
            if manual {
                tell("Blackout \(version) is the latest version.")
            }
        case .success(.available(let release)):
            lastAnswer = Date()
            available = release
            state = .available(release.version)
            Logger.info("Update check: \(release.version) is available")
            if manual {
                offer(release)
            }
        case .failure(let error):
            // The menu keeps what the last good answer said
            Logger.error("Update check failed: \(error.localizedDescription)")
            if manual {
                tell("Could not check for updates", detail: error.localizedDescription)
            }
        }
    }

    // MARK: - Installing

    /// "Update to …" in the menu: install what the last check found
    func installAvailable() {
        guard let available else { return }
        install(available)
    }

    private func install(_ release: Release) {
        guard !isInstalling else { return }
        state = .installing(release.version)
        Logger.info("Updating to \(release.version)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Updater.download(release, into: PathManager.updateDirectory) }
            DispatchQueue.main.async {
                self?.downloaded(result, release: release)
            }
        }
    }

    private func downloaded(_ result: Result<URL, Error>, release: Release) {
        let app: URL
        switch result {
        case .success(let unpacked):
            app = unpacked
        case .failure(let error):
            failed(release, error.localizedDescription)
            return
        }

        // Its output goes to this app's log, where Open Log finds it
        guard let pid = Updater.startInstall(app, log: PathManager.daemonLog) else {
            failed(release, "The installer could not be started.")
            return
        }
        Logger.info("Started the installer of \(release.version) (PID \(pid))")

        // A working install stops this app before the installer ends. Still
        // running when it ends means it gave up before replacing anything.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let status = Updater.waitForInstall(pid)
            DispatchQueue.main.async {
                if status == 0 {
                    self?.failed(release, "The installer finished but did not restart Blackout. Quit Blackout and open it again from Applications.")
                } else {
                    self?.failed(release, "The installer stopped with status \(status). Open Log shows its output.")
                }
            }
        }
    }

    private func failed(_ release: Release, _ message: String) {
        Logger.error("Update to \(release.version) failed: \(message)")
        state = .available(release.version)
        tell("Could not update to Blackout \(release.version)", detail: message)
    }

    // MARK: - Alerts

    private func tell(_ message: String, detail: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        if let detail {
            alert.informativeText = detail
        }
        alert.runModal()
    }

    private func offer(_ release: Release) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Blackout \(release.version) is available"
        if let version {
            alert.informativeText = "You have \(version). Updating takes a few seconds; the menu bar icon disappears and comes back."
        }
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            install(release)
        }
    }
}
