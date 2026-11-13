import Foundation

/// The output volume (0 - 100) and whether output is muted
public struct OutputAudio: Equatable {
    public var volume: Int
    public var muted: Bool

    public init(volume: Int, muted: Bool) {
        self.volume = volume
        self.muted = muted
    }
}

public struct AudioController {

    /// Get the current output volume and mute state, in one osascript call
    public static func getOutput() -> OutputAudio {
        let settings = Shell.output("/usr/bin/osascript", ["-e", "get volume settings"]) ?? ""
        return parseVolumeSettings(settings)
    }

    /// Parse the text `get volume settings` prints, e.g.
    /// "output volume:44, input volume:100, alert volume:100, output muted:false"
    public static func parseVolumeSettings(_ text: String) -> OutputAudio {
        var values: [String: String] = [:]
        for pair in text.split(separator: ",") {
            let parts = pair.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return OutputAudio(
            // Fallback: 50 if we can't read volume
            volume: values["output volume"].flatMap { Int($0) } ?? 50,
            muted: values["output muted"] == "true"
        )
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
