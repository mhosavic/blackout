import Foundation
import CoreGraphics

// DisplayServices framework for Apple Silicon (M1/M2/M3/M4)
@_silgen_name("DisplayServicesGetBrightness")
func DisplayServicesGetBrightness(_ display: CGDirectDisplayID, _ brightness: UnsafeMutablePointer<Float>) -> Int32

@_silgen_name("DisplayServicesSetBrightness")
func DisplayServicesSetBrightness(_ display: CGDirectDisplayID, _ brightness: Float) -> Int32

struct BrightnessController {

    /// Get the current brightness of the main display (0.0 - 1.0)
    static func getBrightness() -> Double {
        let displayID = CGMainDisplayID()
        var brightness: Float = 0.0
        let result = DisplayServicesGetBrightness(displayID, &brightness)
        if result == 0 {
            return Double(brightness)
        }
        // Fallback: return 1.0 if we can't read brightness
        return 1.0
    }

    /// Set the brightness of the main display (0.0 - 1.0)
    static func setBrightness(_ value: Double) {
        let displayID = CGMainDisplayID()
        let clampedValue = Float(min(max(value, 0.0), 1.0))
        _ = DisplayServicesSetBrightness(displayID, clampedValue)
    }

    /// Dim the screen completely
    static func dimScreen() {
        setBrightness(0.0)
    }
}
