import Foundation
import CoreGraphics

public struct BrightnessController {

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    /// DisplayServices is the private framework behind the brightness keys on
    /// Apple Silicon. Resolved at runtime, like the screen lock, so the
    /// package needs no private-framework linker flags and a macOS update
    /// that removes it degrades to "brightness unchanged" instead of a
    /// binary that will not launch. Resolved once; the handle is never closed.
    private static let functions: (get: GetBrightness, set: SetBrightness)? = {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return (unsafeBitCast(get, to: GetBrightness.self), unsafeBitCast(set, to: SetBrightness.self))
    }()

    /// Whether brightness can be read and set, without doing either
    public static func isAvailable() -> Bool {
        return functions != nil
    }

    /// The display blackout dims: the built-in panel, which is not always the
    /// main display — with the menu bar on an external monitor the main
    /// display is that monitor, and DisplayServices cannot drive it. Falls
    /// back to the main display when no built-in is online (lid shut).
    public static func builtinDisplay(
        among displays: [CGDirectDisplayID],
        isBuiltin: (CGDirectDisplayID) -> Bool,
        main: CGDirectDisplayID
    ) -> CGDirectDisplayID {
        return displays.first(where: isBuiltin) ?? main
    }

    private static func targetDisplay() -> CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return CGMainDisplayID() }
        return builtinDisplay(
            among: Array(ids.prefix(Int(count))),
            isBuiltin: { CGDisplayIsBuiltin($0) != 0 },
            main: CGMainDisplayID()
        )
    }

    /// Get the current brightness of the built-in display (0.0 - 1.0)
    public static func getBrightness() -> Double {
        var brightness: Float = 0.0
        if let functions, functions.get(targetDisplay(), &brightness) == 0 {
            return Double(brightness)
        }
        // Fallback: return 1.0 if we can't read brightness
        return 1.0
    }

    /// Set the brightness of the built-in display (0.0 - 1.0)
    public static func setBrightness(_ value: Double) {
        let clampedValue = Float(min(max(value, 0.0), 1.0))
        _ = functions?.set(targetDisplay(), clampedValue)
    }

    /// Dim the screen completely
    public static func dimScreen() {
        setBrightness(0.0)
    }
}
