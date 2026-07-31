import Foundation

public struct ExternalDisplayController {

    /// Full path to m1ddc, resolved once per run. Homebrew locations are
    /// checked explicitly because the hotkey daemon runs under launchd,
    /// whose PATH does not include them.
    private static let m1ddcPath: String? = {
        let candidates = ["/opt/homebrew/bin/m1ddc", "/usr/local/bin/m1ddc"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        return Shell.output("/usr/bin/which", ["m1ddc"])
    }()

    /// Get the current luminance of external display (0 - 100, or nil if unavailable)
    public static func getLuminance() -> Int? {
        guard let m1ddc = m1ddcPath else { return nil }

        if let output = Shell.output(m1ddc, ["get", "luminance"]),
           let luminance = Int(output) {
            // Some monitors return negative values; default to 15 in that case
            return luminance >= 0 ? luminance : 15
        }
        return nil
    }

    /// Set the luminance of external display
    public static func setLuminance(_ level: Int) {
        guard let m1ddc = m1ddcPath else { return }
        Shell.run(m1ddc, ["set", "luminance", String(level)])
    }

    /// Dim external display to minimum
    public static func dim() {
        setLuminance(0)
    }
}
