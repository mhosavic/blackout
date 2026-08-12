import Foundation
import IOKit

public struct LidLockController {

    /// What the lid did between two observations
    public enum LidTransition {
        case closed
        case opened
        case none
    }

    /// Message IOPMrootDomain posts when the lid opens or closes. Swift cannot
    /// import kIOPMMessageClamshellStateChange because it is a function-like
    /// macro, iokit_family_msg(sub_iokit_powermanagement, 0x100). Re-derive with
    /// a one-line C program printing the macro from <IOKit/pwr_mgt/IOPM.h>.
    static let clamshellStateChanged: UInt32 = 0xE003_4100

    /// Current lid state, or nil when IOPMrootDomain has no clamshell property
    /// (desktop Macs, or a future OS renaming it)
    public static func isLidClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        let property = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue()

        return property as? Bool
    }

    /// Classify a lid observation. The clamshell message also fires when
    /// AppleClamshellCausesSleep changes, so an unchanged state is no event,
    /// and a nil previous is the watcher's first look — a baseline only.
    public static func transition(previous: Bool?, current: Bool) -> LidTransition {
        guard let previous, previous != current else { return .none }
        return current ? .closed : .opened
    }
}
