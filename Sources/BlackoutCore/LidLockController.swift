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

    // MARK: - Locking

    /// SACLockScreenImmediate is the same lock as ⌃⌘Q: immediate regardless of
    /// the "require password after…" grace period, Touch ID still unlocks, and
    /// every process keeps running. Private API, so it is resolved at runtime
    /// and its absence degrades to a reported warning rather than a crash.
    /// Resolved once — the handle is deliberately never closed, since the
    /// function pointer stays live for the life of the process.
    private static let lockFunction: (@convention(c) () -> Void)? = {
        let path = "/System/Library/PrivateFrameworks/login.framework/login"
        guard let handle = dlopen(path, RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) () -> Void).self)
    }()

    /// Whether the screen can be locked, without locking it
    public static func isLockAvailable() -> Bool {
        return lockFunction != nil
    }

    /// Lock the screen immediately. Returns false if the symbol is unavailable.
    @discardableResult
    public static func lockScreen() -> Bool {
        guard let lock = lockFunction else { return false }
        lock()
        return true
    }
}
