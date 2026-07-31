import Foundation

public struct AudioController {

    /// Get the current output volume (0 - 100)
    public static func getVolume() -> Int {
        if let output = Shell.output("/usr/bin/osascript", ["-e", "output volume of (get volume settings)"]),
           let volume = Int(output) {
            return volume
        }
        // Fallback: return 50 if we can't read volume
        return 50
    }

    /// Set the output volume (0 - 100)
    public static func setVolume(_ level: Int) {
        let clampedLevel = min(max(level, 0), 100)
        Shell.run("/usr/bin/osascript", ["-e", "set volume output volume \(clampedLevel)"])
    }

    /// Mute the audio completely
    public static func mute() {
        Shell.run("/usr/bin/osascript", ["-e", "set volume output muted true"])
    }

    /// Unmute the audio
    public static func unmute() {
        Shell.run("/usr/bin/osascript", ["-e", "set volume output muted false"])
    }
}
