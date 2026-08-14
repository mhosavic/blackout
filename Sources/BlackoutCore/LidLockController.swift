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

    /// Whether closing the lid should lock, decided at the close edge from
    /// live evidence rather than once at enable time. Skip only when an
    /// external display is online right now AND it was left undimmed (docked
    /// use: the lid is a keyboard cover, not the last screen). With -e the
    /// external is dark too, so the lid close locks regardless.
    public static func shouldLockOnLidClose(externalOnline: Bool, externalWasDimmed: Bool) -> Bool {
        return !externalOnline || externalWasDimmed
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

    // MARK: - Watcher process

    /// Spawn the detached watcher that reacts to the lid and the unlock.
    /// stdio goes to /dev/null: the hotkey daemon reads blackout's stdout to
    /// EOF, so a surviving child holding that pipe would deadlock it for the
    /// whole session — the same trap already fixed for caffeinate.
    public static func startWatcher() -> pid_t? {
        guard let executable = Bundle.main.executablePath else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--lid-watch"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            return process.processIdentifier
        } catch {
            return nil
        }
    }

    /// Stop a watcher started by startWatcher()
    public static func stopWatcher(pid: pid_t) {
        kill(pid, SIGTERM)
    }

    /// Watch the lid and the lock screen, calling back on each event. The lid
    /// open callback receives whether the screen is currently locked, so the
    /// caller can restore for a readable lock screen or re-dim a docked cycle.
    /// Blocks on the current run loop and does not return while watching;
    /// returns false if the notification could not be registered.
    @discardableResult
    public static func watch(
        onLidClose: @escaping () -> Void,
        onLidOpen: @escaping (_ screenLocked: Bool) -> Void,
        onUnlock: @escaping () -> Void
    ) -> Bool {
        let watcher = LidWatcher(onLidClose: onLidClose, onLidOpen: onLidOpen, onUnlock: onUnlock)
        guard watcher.start() else { return false }

        withExtendedLifetime(watcher) {
            CFRunLoopRun()
        }
        return true
    }
}

/// Holds the IOKit subscription and the previous lid state. A class because the
/// C callback carries an opaque context pointer, and the state must survive
/// between callbacks.
private final class LidWatcher {

    private let onLidClose: () -> Void
    private let onLidOpen: (Bool) -> Void
    private let onUnlock: () -> Void
    private var previous: Bool?
    // Maintained by the screenIsLocked/Unlocked observers. Seeded false:
    // enabling blackout requires an unlocked session (hotkey or CLI).
    private var screenLocked = false
    private var notification: io_object_t = 0

    init(
        onLidClose: @escaping () -> Void,
        onLidOpen: @escaping (Bool) -> Void,
        onUnlock: @escaping () -> Void
    ) {
        self.onLidClose = onLidClose
        self.onLidOpen = onLidOpen
        self.onUnlock = onUnlock
        // Seed from the current state so enabling blackout with the lid
        // already shut does not lock immediately
        self.previous = LidLockController.isLidClosed()
    }

    func start() -> Bool {
        // Unlocking is what ends a session, so it is watched separately from
        // the lid: anyone can lift a lid, only the owner can authenticate.
        // Observers run on the main queue — the same thread CFRunLoopRun
        // occupies — so screenLocked is never touched from two threads.
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.screenLocked = true
        }
        center.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.screenLocked = false
            self?.onUnlock()
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return false }
        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
            .defaultMode
        )

        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = IOServiceAddInterestNotification(
            port,
            service,
            kIOGeneralInterest,
            { context, _, messageType, _ in
                guard let context else { return }
                Unmanaged<LidWatcher>.fromOpaque(context)
                    .takeUnretainedValue()
                    .handle(messageType: messageType)
            },
            context,
            &notification
        )

        return status == KERN_SUCCESS
    }

    private func handle(messageType: UInt32) {
        guard messageType == LidLockController.clamshellStateChanged,
              let current = LidLockController.isLidClosed() else { return }

        let transition = LidLockController.transition(previous: previous, current: current)
        previous = current

        switch transition {
        case .closed: onLidClose()
        case .opened: onLidOpen(screenLocked)
        case .none: break
        }
    }
}
