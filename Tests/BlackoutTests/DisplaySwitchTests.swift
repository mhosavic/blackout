import Testing
import BlackoutCore

struct DisplaySwitchTests {

    /// The one rule that must never break: a display is not switched off
    /// unless another one stays on
    @Test func neverSwitchesOffTheLastDisplay() {
        #expect(DisplaySwitch.maySwitchOff(1, online: [1, 3]))
        #expect(!DisplaySwitch.maySwitchOff(1, online: [1]))
        #expect(!DisplaySwitch.maySwitchOff(1, online: []))
        // Already off (not listed): nothing to do, and not a reason to try
        #expect(!DisplaySwitch.maySwitchOff(1, online: [3]))
    }

    /// The call is undocumented; this is the early warning if a macOS
    /// update removes it
    @Test func switchCallResolvesOnThisMachine() {
        #expect(DisplaySwitch.isAvailable())
    }
}
