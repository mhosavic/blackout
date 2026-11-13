import Testing
import CoreGraphics
import BlackoutCore

struct BrightnessControllerTests {

    /// With the external set as the main display, the main display is not
    /// the panel blackout is meant to dim
    @Test func picksTheBuiltinDisplay() {
        let picked = BrightnessController.builtinDisplay(among: [7, 3, 9], isBuiltin: { $0 == 3 }, main: 7)
        #expect(picked == 3)
    }

    @Test func fallsBackToMainWithoutABuiltin() {
        let picked = BrightnessController.builtinDisplay(among: [7, 9], isBuiltin: { _ in false }, main: 7)
        #expect(picked == 7)
    }

    /// The brightness calls are private API resolved at runtime; this is the
    /// early warning if a macOS update removes them
    @Test func brightnessSymbolsResolveOnThisMachine() {
        #expect(BrightnessController.isAvailable())
    }
}
