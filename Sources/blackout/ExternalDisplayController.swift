import Foundation

struct ExternalDisplayController {

    /// Check if m1ddc is available
    static func isAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["m1ddc"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Get the current luminance of external display (0 - 100, or nil if unavailable)
    static func getLuminance() -> Int? {
        guard isAvailable() else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["m1ddc", "get", "luminance"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let luminance = Int(output) {
                // Some monitors return negative values; default to 15 in that case
                return luminance >= 0 ? luminance : 15
            }
        } catch {
            // Silently fail
        }
        return nil
    }

    /// Set the luminance of external display
    static func setLuminance(_ level: Int) {
        guard isAvailable() else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["m1ddc", "set", "luminance", String(level)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Silently fail
        }
    }

    /// Dim external display to minimum
    static func dim() {
        setLuminance(0)
    }

    /// Check if an external display is connected
    static func isConnected() -> Bool {
        return getLuminance() != nil
    }
}
