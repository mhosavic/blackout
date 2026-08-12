# Lock on Lid Close Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While blackout is active, closing the MacBook lid locks the screen immediately without sleeping the machine; opening it shows a readable lock screen; unlocking ends the blackout session.

**Architecture:** A new `LidLockController` in `BlackoutCore` owns the mechanisms: reading the lid state from `IOPMrootDomain` via IOKit, observing `com.apple.screenIsUnlocked`, and calling `SACLockScreenImmediate()` resolved at runtime from `login.framework`. `enable()` spawns a detached `blackout --lid-watch` process that parks on a CFRunLoop; its PID is recorded in the state file next to `caffeinatePID` and SIGTERM'd by `disable()`. Policy lives in `main.swift`, where the watcher's three handlers can reach `disable()` and the brightness controllers directly.

**Tech Stack:** Swift 6 toolchain in language mode 5, SwiftPM, IOKit (public API), `dlopen`/`dlsym` against `login.framework` (private but long-stable), `DistributedNotificationCenter`, swift-testing.

Full design rationale, including the alternatives that were tested and rejected: `docs/superpowers/specs/2026-08-12-lock-on-lid-close-design.md`.

## Global Constraints

- Target platform is `.macOS(.v14)`; the repo builds with Command Line Tools, no full Xcode.
- **Run tests with `swift run blackout-tests`, never `swift test`.** The suite is an `executableTarget`, not a `testTarget` — `swift test` reports "no tests found". Filter with `swift run blackout-tests --filter <testName>`.
- No new third-party dependencies. IOKit is a system framework; `dlopen` needs no linkage.
- All targets use `.swiftLanguageMode(.v5)`.
- Commit messages: imperative mood, one line, under 72 chars, explaining *why* rather than *what*. No `feat:`/`fix:` prefixes — the repo does not use them.
- Match the surrounding comment style: comments explain *why* a non-obvious choice was made, and are omitted where the code is self-evident.
- The watcher's stdio is `/dev/null` and must stay that way, so **anything the user must know about has to go through `NotificationManager`, not `print`.**
- Never call `LidLockController.startWatcher()` from a test. It spawns `Bundle.main.executablePath`, which inside the test binary is `blackout-tests` — the suite would fork itself.
- Never call `LidLockController.lockScreen()` from a test. It really does lock the screen.

---

### Task 1: Lid state and transitions

The pure, testable core: read the clamshell state, and classify a change. `IOPMrootDomain` posts its clamshell message for `AppleClamshellCausesSleep` changes too, so an unchanged state is not an event.

**Files:**
- Create: `Sources/BlackoutCore/LidLockController.swift`
- Test: `Tests/BlackoutTests/LidLockControllerTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `LidLockController.LidTransition` (`.closed` / `.opened` / `.none`), `LidLockController.isLidClosed() -> Bool?` (nil when the property is absent, e.g. a desktop Mac), `LidLockController.transition(previous: Bool?, current: Bool) -> LidTransition`, `LidLockController.clamshellStateChanged: UInt32` (module-internal).

- [ ] **Step 1: Write the failing tests**

Create `Tests/BlackoutTests/LidLockControllerTests.swift`:

```swift
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
}
```

Note the `LidLockController.LidTransition.none` spelling in the `.none` comparisons: a bare `.none` would be inferred as `Optional.none` and compare wrongly.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift run blackout-tests --filter LidLockControllerTests`
Expected: compile error — `cannot find 'LidLockController' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/BlackoutCore/LidLockController.swift`:

```swift
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift run blackout-tests --filter LidLockControllerTests`
Expected: PASS, 5 tests.

If the build fails to link IOKit, add `linkerSettings: [.linkedFramework("IOKit")]` to the `BlackoutCore` target in `Package.swift`. It is expected to autolink without this.

- [ ] **Step 5: Commit**

```bash
git add Sources/BlackoutCore/LidLockController.swift Tests/BlackoutTests/LidLockControllerTests.swift
git commit -m "Read lid state so blackout can react to the lid moving"
```

---

### Task 2: Locking the screen

Resolve `SACLockScreenImmediate` once per process and expose an availability probe, so `enable()` can report honestly instead of spawning a watcher that could never lock.

**Files:**
- Modify: `Sources/BlackoutCore/LidLockController.swift`
- Test: `Tests/BlackoutTests/LidLockControllerTests.swift`

**Interfaces:**
- Consumes: `LidLockController` from Task 1.
- Produces: `LidLockController.isLockAvailable() -> Bool`, `LidLockController.lockScreen() -> Bool` (`@discardableResult`, false when the symbol is missing).

- [ ] **Step 1: Write the failing test**

Append to `LidLockControllerTests`, inside the `// MARK: - Environment` section:

```swift
    /// Environment assertion: SACLockScreenImmediate is private API, so this
    /// test is the tripwire for the day an OS update removes it. lockScreen()
    /// itself is untestable — it would lock the screen running the tests.
    @Test func lockSymbolIsAvailableOnThisMachine() {
        #expect(LidLockController.isLockAvailable())
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift run blackout-tests --filter lockSymbolIsAvailableOnThisMachine`
Expected: compile error — `type 'LidLockController' has no member 'isLockAvailable'`.

- [ ] **Step 3: Write the implementation**

Add to `LidLockController`, after `transition`:

```swift
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift run blackout-tests --filter LidLockControllerTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/BlackoutCore/LidLockController.swift Tests/BlackoutTests/LidLockControllerTests.swift
git commit -m "Resolve the screen lock at runtime so a missing symbol degrades"
```

---

### Task 3: The watcher — lid edges, unlock, and process lifecycle

The long-lived half: subscribe to clamshell notifications and to `com.apple.screenIsUnlocked`, plus spawn/stop helpers for the detached watcher process. This task delivers mechanism only — what to *do* on each event is Task 5's job.

**Files:**
- Modify: `Sources/BlackoutCore/LidLockController.swift`
- Test: `Tests/BlackoutTests/LidLockControllerTests.swift`

**Interfaces:**
- Consumes: `isLidClosed()`, `transition(previous:current:)`, `clamshellStateChanged` from Task 1.
- Produces: `LidLockController.watch(onLidClose:onLidOpen:onUnlock:) -> Bool` (blocks forever on success, returns false if the IOKit notification could not be registered), `LidLockController.startWatcher() -> pid_t?`, `LidLockController.stopWatcher(pid: pid_t)`.

- [ ] **Step 1: Write the failing test**

Append to `LidLockControllerTests`, before the `// MARK: - Environment` section:

```swift
    // MARK: - Watcher process

    /// startWatcher() is deliberately not tested: it spawns
    /// Bundle.main.executablePath, which in the test binary is blackout-tests
    /// itself. Only the teardown half is exercised here.
    @Test func stopWatcherTerminatesTheProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        #expect(SleepController.isProcessRunning(pid: process.processIdentifier))

        LidLockController.stopWatcher(pid: process.processIdentifier)
        process.waitUntilExit()

        #expect(!SleepController.isProcessRunning(pid: process.processIdentifier))
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift run blackout-tests --filter stopWatcherTerminatesTheProcess`
Expected: compile error — `type 'LidLockController' has no member 'stopWatcher'`.

- [ ] **Step 3: Write the implementation**

Add to `LidLockController`, after `lockScreen()`:

```swift
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

    /// Watch the lid and the lock screen, calling back on each event. Blocks on
    /// the current run loop and does not return while watching; returns false
    /// if the notification could not be registered.
    @discardableResult
    public static func watch(
        onLidClose: @escaping () -> Void,
        onLidOpen: @escaping () -> Void,
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
    private let onLidOpen: () -> Void
    private let onUnlock: () -> Void
    private var previous: Bool?
    private var notification: io_object_t = 0

    init(
        onLidClose: @escaping () -> Void,
        onLidOpen: @escaping () -> Void,
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
        // the lid: anyone can lift a lid, only the owner can authenticate
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
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
        case .opened: onLidOpen()
        case .none: break
        }
    }
}
```

Note the closing brace: `watch` is the last member of `LidLockController`, and `LidWatcher` is a file-private type declared after it.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift run blackout-tests --filter LidLockControllerTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/BlackoutCore/LidLockController.swift Tests/BlackoutTests/LidLockControllerTests.swift
git commit -m "Watch the lid and the unlock so the session can respond to both"
```

---

### Task 4: Record the watcher PID in session state

`disable()` has to find the watcher to kill it, the same way it finds caffeinate.

**Files:**
- Modify: `Sources/BlackoutCore/StateManager.swift`
- Modify: `Tests/BlackoutTests/StateManagerTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `BlackoutState.lidWatcherPID: Int32?`, and `StateManager.saveState(brightness:volume:externalLuminance:pid:sleepDisabled:lidWatcherPID:) -> Bool` with `lidWatcherPID: pid_t?` as the new final parameter.

The parameter is required rather than defaulted, matching `sleepDisabled`, so every call site states its intent. That breaks four existing test call sites, which this task updates.

- [ ] **Step 1: Write the failing tests**

In `Tests/BlackoutTests/StateManagerTests.swift`, update the four existing `saveState` calls to pass the new argument, and extend two assertions:

- Line 27 → `let saved = StateManager.saveState(brightness: 0.42, volume: 37, externalLuminance: 80, pid: 12345, sleepDisabled: true, lidWatcherPID: 54321)`, and add `#expect(state?.lidWatcherPID == 54321)` to that test.
- Line 39 → append `, lidWatcherPID: nil`, and add `#expect(state?.lidWatcherPID == nil)` to that test.
- Line 80 → append `, lidWatcherPID: nil`.
- Line 96 → append `, lidWatcherPID: nil`.

Then add one assertion to the existing legacy-decode test, after line 66:

```swift
        #expect(state?.lidWatcherPID == nil)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift run blackout-tests --filter StateManagerTests`
Expected: compile error — `extra argument 'lidWatcherPID' in call`.

- [ ] **Step 3: Write the implementation**

In `Sources/BlackoutCore/StateManager.swift`, add the field to `BlackoutState` after `sleepDisabled`:

```swift
    public let lidWatcherPID: Int32?
```

The existing comment above `sleepDisabled` ("Optional so state files written by older versions still decode") now covers both fields; leave it where it is.

Then add the parameter to `saveState` and thread it into the initializer:

```swift
    public static func saveState(brightness: Double, volume: Int?, externalLuminance: Int?, pid: pid_t, sleepDisabled: Bool, lidWatcherPID: pid_t?) -> Bool {
        let state = BlackoutState(
            originalBrightness: brightness,
            originalVolume: volume,
            externalLuminance: externalLuminance,
            caffeinatePID: pid,
            sleepDisabled: sleepDisabled,
            lidWatcherPID: lidWatcherPID,
            activatedAt: Date()
        )
```

The rest of `saveState` is unchanged. Member order in the initializer must match the property order in `BlackoutState`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift run blackout-tests`
Expected: PASS, 22 tests in 3 suites. (`Sources/blackout/main.swift` does not compile yet — it still calls the old `saveState` signature. `swift run blackout-tests` only builds `BlackoutCore` and the test target, so this task is verifiable on its own; Task 5 fixes the CLI.)

- [ ] **Step 5: Commit**

```bash
git add Sources/BlackoutCore/StateManager.swift Tests/BlackoutTests/StateManagerTests.swift
git commit -m "Track the lid watcher in state so disable can stop it"
```

---

### Task 5: Wire the CLI and the watcher's policy

The flag, the internal watcher mode with its three handlers, and the two places `disable()` has to change.

**Files:**
- Modify: `Sources/BlackoutCore/NotificationManager.swift`
- Modify: `Sources/blackout/main.swift`

**Interfaces:**
- Consumes: everything produced by Tasks 1–4.
- Produces: the `--no-lock` / `-k` flag, the internal `--lid-watch` mode, `NotificationManager.showSleepRestoreFailed()`, and `restoreDisplays(state:)` in `main.swift`.

- [ ] **Step 1: Add the failure notification**

In `Sources/BlackoutCore/NotificationManager.swift`, add after `showDisabled()`:

```swift
    /// Shown when re-enabling sleep failed. The watcher's stdout goes to
    /// /dev/null, so on the auto-disable path this notification is the only way
    /// the user ever learns their Mac will not sleep.
    public static func showSleepRestoreFailed() {
        showNotification(
            title: "Blackout",
            message: "Could not re-enable sleep. Run: sudo pmset -a disablesleep 0"
        )
    }
```

- [ ] **Step 2: Add the flag and the watcher mode**

In `Sources/blackout/main.swift`, add after the `noLidFlag` line (line 11):

```swift
let noLockFlag = args.contains("--no-lock") || args.contains("-k")
```

Then add the internal mode immediately after it, above the `--setup-lid` block. It must come before any state handling, since the watcher is not a toggle. `restoreDisplays` and `disable` are defined later in the file, which is fine — top-level functions are visible throughout:

```swift
// Internal mode: the detached watcher spawned by enable(). Not in --help —
// users never run it directly, but it is visible in `ps` as `blackout --lid-watch`.
// Each handler reloads state: if the session ended without this process being
// killed, there is nothing left to act on.
if args.contains("--lid-watch") {
    let watching = LidLockController.watch(
        onLidClose: {
            guard let state = StateManager.loadState() else { exit(0) }
            // Undo the dim before locking. The panel may already be powering
            // down, so this is best-effort; the open handler is the one that
            // has to land.
            restoreDisplays(state: state)
            LidLockController.lockScreen()
        },
        onLidOpen: {
            guard let state = StateManager.loadState() else { exit(0) }
            // Without this the lock screen is a black rectangle and the
            // password field cannot be seen
            restoreDisplays(state: state)
        },
        onUnlock: {
            guard let state = StateManager.loadState() else { exit(0) }
            // Authenticating means the owner is back: end the session so the
            // restored brightness keeps telling the truth about blackout
            disable(state: state)
            exit(0)
        }
    )
    exit(watching ? 0 : 1)
}
```

`watch` does not return while it is watching, so `exit(0)` there is unreachable in practice; it exists so the failure path exits nonzero.

- [ ] **Step 3: Add the display restore helper**

Add above `func enable(...)` in `main.swift`:

```swift
/// Bring the panels back to what the user had. Idempotent — disable() sets the
/// same values again — so the watcher can call it on every lid event.
func restoreDisplays(state: BlackoutState) {
    BrightnessController.setBrightness(state.originalBrightness)
    if let extLum = state.externalLuminance {
        ExternalDisplayController.setLuminance(extLum)
    }
}
```

- [ ] **Step 4: Add `-k` to the help text**

In the options block, after the `--no-lid` line (line 44):

```swift
    print("  -k, --no-lock      Skip locking the screen when the lid closes")
```

Then replace the two description lines starting `print("after --setup-lid). Audio is automatically kept unmuted when an external")` with:

```swift
    print("after --setup-lid) and locks the screen when the lid closes — unlocking")
    print("then ends blackout. Audio is automatically kept unmuted when an external")
    print("monitor is detected, which also leaves the lid lock off. Run again to")
    print("restore original settings.")
```

Delete the now-duplicated `print("monitor is detected. Run again to restore original settings.")` line.

- [ ] **Step 5: Update the `enable()` signature and decide the lock**

Change the signature (line 65) to:

```swift
func enable(dimExternal: Bool, noMute: Bool, noLid: Bool, noLock: Bool) {
```

Add after `let skipMute = noMute || hasExternalDisplay` (line 71):

```swift
    // An external display left on means the lid is a keyboard cover, not a
    // screen — docked clamshell work must not lock. With --dim-external
    // everything is dark and locking is the point.
    let externalLeftOn = hasExternalDisplay && !dimExternal
    let lockOnLid = !noLock && !externalLeftOn && LidLockController.isLockAvailable()
```

Then, after the lid-sleep block (after line 94) and before `saveState`, spawn the watcher:

```swift
    let lidWatcherPID = lockOnLid ? LidLockController.startWatcher() : nil
```

- [ ] **Step 6: Thread the PID through save and rollback**

Update the `saveState` call (line 98) to pass `lidWatcherPID: lidWatcherPID`, and add the watcher to the rollback inside that `guard`, after `SleepController.allowSleep(pid: pid)`:

```swift
        if let watcherPID = lidWatcherPID {
            LidLockController.stopWatcher(pid: watcherPID)
        }
```

- [ ] **Step 7: Report the lock in the status block**

After the lid-sleep status lines (after line 141), add:

```swift
    if lidWatcherPID != nil {
        print("  Lock on lid close: armed (unlocking ends blackout)")
    } else if noLock {
        print("  Lock on lid close: skipped (--no-lock)")
    } else if externalLeftOn {
        print("  Lock on lid close: skipped (external monitor left on)")
    } else if !LidLockController.isLockAvailable() {
        print("  Lock on lid close: unavailable (SACLockScreenImmediate not found)")
    } else {
        print("  Lock on lid close: failed to start the watcher")
    }
```

- [ ] **Step 8: Stop the watcher in `disable()`, and notify on a failed sleep restore**

In `disable(state:)`, after the caffeinate block (after line 152):

```swift
    // Stop the lid watcher. Skip our own PID: on the unlock path this function
    // runs inside the watcher, and SIGTERMing ourselves here would abandon the
    // restore half-done. A dead or missing PID just means it already exited.
    if let watcherPID = state.lidWatcherPID,
       watcherPID != ProcessInfo.processInfo.processIdentifier,
       SleepController.isProcessRunning(pid: watcherPID) {
        LidLockController.stopWatcher(pid: watcherPID)
    }
```

Then, in the warning branch at the end of `disable()`, add the notification after the two `print` lines:

```swift
        NotificationManager.showSleepRestoreFailed()
```

- [ ] **Step 9: Pass the flag at the call site**

Update the final `enable(...)` call (line 203):

```swift
    enable(dimExternal: dimExternalFlag, noMute: noMuteFlag, noLid: noLidFlag, noLock: noLockFlag)
```

- [ ] **Step 10: Build and run the full suite**

Run: `swift build && swift run blackout-tests`
Expected: build succeeds, 22 tests pass.

- [ ] **Step 11: Verify by hand**

These cover what no unit test can. Run from a real Terminal window on the laptop:

```bash
swift build -c release
.build/release/blackout            # expect "armed (unlocking ends blackout)"
pgrep -fl "blackout --lid-watch"   # expect one process
```

Close the lid, wait ~5 seconds, open it. Expected, in order:

1. The lock screen is **readable**, not black — this is the whole point of the brightness restore.
2. Unlock. Brightness and volume are restored, the "Brightness restored." notification appears, and:

```bash
pmset -g | grep SleepDisabled      # expect 0 — the session ended
pgrep -fl "blackout --lid-watch"   # expect no output
ls ~/.blackout.state               # expect "No such file"
```

Then the survival case — the session must outlive a lid open that is *not* authenticated:

```bash
.build/release/blackout
```

Close the lid, open it, and **do not unlock**. Close it again. Open it and check from another machine over SSH, or after unlocking:

```bash
pmset -g | grep SleepDisabled      # expect 1 while it was locked
```

Then the skip paths:

```bash
.build/release/blackout --no-lock  # expect "skipped (--no-lock)", no watcher
.build/release/blackout            # toggle off
```

With an external monitor connected, `blackout` should print `skipped (external monitor left on)` and spawn no watcher, while `blackout -e` should print `armed`.

Finally the daemon path, which is where a stdio mistake would show up: with the daemon installed, press ⌃⌥⌘\ twice. Both toggles must complete and `~/.blackout/daemon.log` must show no hang.

**If closing the lid does not lock:** the one assumption this design could not verify up front is that `kIOPMMessageClamshellStateChange` still fires while `SleepDisabled` is 1. Diagnose by running `.build/release/blackout --lid-watch` in a Terminal with a temporary `print` in `handle(messageType:)` — if no message arrives on lid close, fall back to polling `isLidClosed()` on a 2-second timer inside `LidWatcher`, which feeds the same `transition` logic and needs no other change.

**If unlocking does not end the session:** confirm the notification name with a temporary observer for `com.apple.screenIsUnlocked` printing to a file. If the name has changed, `com.apple.sessionDidBecomeActive` is the fallback.

- [ ] **Step 12: Commit**

```bash
git add Sources/BlackoutCore/NotificationManager.swift Sources/blackout/main.swift
git commit -m "Lock on lid close and end blackout when the owner unlocks"
```

---

### Task 6: Cleanup path and documentation

The uninstall script has a fallback for a caffeinate the toggle failed to clean up; the watcher needs the same. Users will also see a second `blackout` process and deserve an explanation.

**Files:**
- Modify: `uninstall.sh:13-20`
- Modify: `README.md`

**Interfaces:**
- Consumes: the `lidWatcherPID` state key from Task 4.
- Produces: nothing.

- [ ] **Step 1: Add the uninstall fallback**

In `uninstall.sh`, after the existing caffeinate fallback block (line 20), add:

```bash
# Fallback: stop any lid watcher the toggle did not clean up
if [ -f ~/.blackout.state ]; then
    PID=$(grep lidWatcherPID ~/.blackout.state | grep -o '[0-9]*')
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        echo "Stopping lid watcher (PID: $PID)..."
        kill "$PID" 2>/dev/null
    fi
fi
```

- [ ] **Step 2: Verify the script still parses**

Run: `bash -n uninstall.sh`
Expected: no output.

- [ ] **Step 3: Update the README options table**

Add a row after the `--no-lid` row (`README.md:85`):

```markdown
| `-k`, `--no-lock` | Skip locking the screen when the lid closes |
```

- [ ] **Step 4: Document the behavior**

In "What happens when enabled" (`README.md:99-105`), insert between the current item 6 (lid-close sleep) and item 7 (notification), so the notification becomes item 8:

```markdown
7. Closing the lid locks the screen immediately — the Mac keeps running, but
   nobody can open the lid into your session. Opening the lid restores
   brightness so the lock screen is readable, and unlocking ends blackout
   entirely. Skipped when an external monitor is left on, so docked clamshell
   use is unaffected.
```

In "What happens when disabled" (`README.md:107-113`), extend item 4 to:

```markdown
4. Sleep prevention is removed, lid-close sleep re-enabled, and the lid watcher stopped
```

- [ ] **Step 5: Add troubleshooting entries**

At the end of the Troubleshooting section, matching its existing `###` heading style:

```markdown
### A second `blackout` process is running

That is the lid watcher (`blackout --lid-watch`). It exists only while blackout
is active and exits when you toggle blackout off — or when you unlock after a
lid close, which ends the session. Disable it with `--no-lock`.

### The lock screen is black after opening the lid

Blackout sets brightness to 0%, and it restores it when the lid opens. If that
did not happen, press the brightness-up key — it works at the lock screen — and
report it: the restore is the part of this feature most likely to be defeated
by a macOS change.

### Closing the lid does not lock the screen

Check the status line printed when blackout starts. `skipped (external monitor
left on)` means an external display is connected — that is deliberate, and
`blackout -e` locks instead. `unavailable` means macOS no longer exposes
`SACLockScreenImmediate`, and locking would need another mechanism.
```

- [ ] **Step 6: Commit**

```bash
git add uninstall.sh README.md
git commit -m "Document the lid lock and clean up its watcher on uninstall"
```

---

## Verification summary

After Task 6, the whole feature is verifiable with:

```bash
swift build && swift run blackout-tests    # 22 tests, 3 suites
bash -n uninstall.sh
```

plus the manual checklist in Task 5, Step 11 — the IOKit callback, the unlock observer, and the lock call itself cannot be covered by the suite.
