import Foundation
import BlackoutCore

/// Runs the blackout CLI for the hotkey and the menu. The CLI stays the one
/// implementation of a session; this only starts it and reports back.
final class Toggler {

    /// How long to wait for a run before accepting presses again. The CLI
    /// bounds its own steps well below this, so reaching it means a hang —
    /// and a hung child must not leave the hotkey dead until the next login.
    private static let patience: TimeInterval = 60

    // Touched on the main thread only
    private var inFlight = false

    /// Run `blackout <command>` off the main thread: "toggle" from the
    /// hotkey, "on" or "off" from the menu. A call made while another is
    /// running is dropped — the usual cause is a second press out of
    /// impatience, which would otherwise undo the first.
    /// `completion` runs on the main thread.
    func run(_ command: String, completion: @escaping () -> Void) {
        guard !inFlight else {
            Logger.info("Ignored 'blackout \(command)': an earlier command is still running")
            return
        }
        guard let binary = Toggler.findBlackoutBinary() else {
            Logger.error("Could not find the blackout binary")
            return
        }

        inFlight = true
        let started = Date()
        var reported = false
        // On the main thread, once: whichever comes first of the child
        // finishing and patience running out
        let finish: (String, Bool) -> Void = { [weak self] message, isError in
            guard !reported else { return }
            reported = true
            self?.inFlight = false
            if isError { Logger.error(message) } else { Logger.info(message) }
            completion()
        }

        Logger.info("Running: \(binary.path) \(command)")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Toggler.execute(binary, command)
            let seconds = String(format: "%.2f", Date().timeIntervalSince(started))
            DispatchQueue.main.async {
                switch result {
                case .success((0, _)):
                    finish("'blackout \(command)' finished in \(seconds)s", false)
                case .success((let status, let output)):
                    finish("'blackout \(command)' exited \(status) after \(seconds)s: \(output)", true)
                case .failure(let error):
                    finish("Failed to run blackout: \(error)", true)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Toggler.patience) {
            finish("'blackout \(command)' still running after \(Int(Toggler.patience))s; accepting presses again", true)
        }
    }

    /// The CLI that ships beside this app in the bundle, so the two can
    /// never be different versions; the PATH locations cover a development
    /// build run outside a bundle
    private static func findBlackoutBinary() -> URL? {
        var candidates: [URL] = []
        if let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("blackout") {
            candidates.append(sibling)
        }
        candidates += [
            PathManager.homeDirectory.appendingPathComponent("bin/blackout"),
            URL(fileURLWithPath: "/usr/local/bin/blackout"),
            URL(fileURLWithPath: "/opt/homebrew/bin/blackout")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func execute(_ binary: URL, _ command: String) -> Result<(Int32, String), Error> {
        let process = Process()
        process.executableURL = binary
        process.arguments = [command]

        // Capture output so failures are diagnosable from the log
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .success((process.terminationStatus, output))
        } catch {
            return .failure(error)
        }
    }
}
