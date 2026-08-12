import Testing
import Foundation
import BlackoutCore

struct LidLockControllerTests {

    // MARK: - Transitions

    @Test func closingTheLidIsAClosedTransition() {
        #expect(LidLockController.transition(previous: false, current: true) == .closed)
    }

    @Test func openingTheLidIsAnOpenedTransition() {
        #expect(LidLockController.transition(previous: true, current: false) == .opened)
    }

    /// IOPMrootDomain posts the same message when AppleClamshellCausesSleep
    /// changes, so an unchanged lid must not read as an event
    @Test func unchangedStateIsNotATransition() {
        #expect(LidLockController.transition(previous: true, current: true) == LidLockController.LidTransition.none)
        #expect(LidLockController.transition(previous: false, current: false) == LidLockController.LidTransition.none)
    }

    /// The watcher seeds its previous state at startup. Whatever the lid is
    /// doing then, the first observation is only a baseline — enabling blackout
    /// with the lid already shut must not lock instantly.
    @Test func firstObservationIsOnlyABaseline() {
        #expect(LidLockController.transition(previous: nil, current: true) == LidLockController.LidTransition.none)
        #expect(LidLockController.transition(previous: nil, current: false) == LidLockController.LidTransition.none)
    }

    // MARK: - Environment

    /// Environment assertion, not a logic test: this feature only makes sense
    /// on a laptop, and a nil here means the IOKit property was renamed or the
    /// build machine has no lid.
    @Test func lidStateIsReadableOnThisMachine() {
        #expect(LidLockController.isLidClosed() != nil)
    }

    /// Environment assertion: SACLockScreenImmediate is private API, so this
    /// test is the tripwire for the day an OS update removes it. lockScreen()
    /// itself is untestable — it would lock the screen running the tests.
    @Test func lockSymbolIsAvailableOnThisMachine() {
        #expect(LidLockController.isLockAvailable())
    }
}
