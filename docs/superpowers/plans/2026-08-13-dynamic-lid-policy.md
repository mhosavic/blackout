# Dynamic Lid Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The lid watcher always runs; lock-or-skip is decided at each lid close from live display presence; docked lid cycles re-dim instead of leaking a bright screen; unlocking ends the session unconditionally.

**Architecture:** Revision of the shipped lock-on-lid-close feature per the 2026-08-13 spec revision (decisions 8–12 in `docs/superpowers/specs/2026-08-12-lock-on-lid-close-design.md`). New pure policy function + CG display-presence probe in `BlackoutCore`; watcher tracks lock state via distributed notifications; `main.swift` handlers become dynamic.

**Tech Stack:** Same as the feature: Swift 6 in language mode 5, IOKit, CoreGraphics (new), DistributedNotificationCenter, swift-testing via `swift run blackout-tests`.

## Global Constraints

- Same as the 2026-08-12 plan: `swift run blackout-tests` (never `swift test`), no new dependencies, `.swiftLanguageMode(.v5)`, imperative one-line commits, never call `startWatcher()`/`lockScreen()` from tests.
- After the final build, **install with `cp .build/release/blackout ~/bin/`** — last time the feature "didn't work" purely because this step was skipped.

---

### Task 1: CG display presence + close-edge policy

**Files:**
- Modify: `Sources/BlackoutCore/ExternalDisplayController.swift` (add `isExternalDisplayOnline()`)
- Modify: `Sources/BlackoutCore/LidLockController.swift` (add `shouldLockOnLidClose`)
- Test: `Tests/BlackoutTests/LidLockControllerTests.swift`

**Interfaces:**
- Produces: `ExternalDisplayController.isExternalDisplayOnline() -> Bool` (false on CG failure → callers fail toward locking), `LidLockController.shouldLockOnLidClose(externalOnline: Bool, externalWasDimmed: Bool) -> Bool`.

Steps: failing tests (4-combo policy table below) → verify fail → implement → verify pass → commit.

| externalOnline | externalWasDimmed | → lock? | why |
|---|---|---|---|
| false | false | true | classic undocked |
| false | true | true | `-e` external unplugged mid-session |
| true | false | false | docked: lid is a keyboard cover |
| true | true | true | `-e`: everything dark, walk away |

### Task 2: Lock-state tracking in the watcher

**Files:**
- Modify: `Sources/BlackoutCore/LidLockController.swift`

**Interfaces:**
- Changes: `watch(onLidClose: @escaping () -> Void, onLidOpen: @escaping (_ screenLocked: Bool) -> Void, onUnlock: @escaping () -> Void)`.
- `LidWatcher` observes `com.apple.screenIsLocked` and `com.apple.screenIsUnlocked` with `queue: .main` (single-threaded state; `CFRunLoopRun` on the main thread drains the main queue). `screenLocked` seeded false — enabling blackout requires an unlocked session. No restore action on lock (spec decision 12).

No new unit test possible (notification-driven); covered by the manual matrix.

### Task 3: Dynamic handlers in main.swift

**Files:**
- Modify: `Sources/blackout/main.swift`

- `lockOnLid` drops the external gate: `!noLock && LidLockController.isLockAvailable()`.
- `onLidClose`: load state; `shouldLockOnLidClose(externalOnline: ExternalDisplayController.isExternalDisplayOnline(), externalWasDimmed: state.externalLuminance != nil)` → restore + lock, else nothing (docked).
- `onLidOpen(screenLocked)`: locked → `restoreDisplays(state:)`; unlocked → `BrightnessController.dimScreen()` (docked re-dim).
- `onUnlock`: unchanged (load state, `disable`, exit) — unconditional.
- Status line: armed + `externalLeftOn` → `armed (lid close skips the lock while the external display is in use)`; armed otherwise → unchanged text.

### Task 4: Docs, build, install

- README: behavior item 7 (lock decided at close time; docked cycle re-dims; unlock always ends), troubleshooting: manual-lock screens stay dark — brightness keys work at the lock screen.
- `swift build -c release && swift run blackout-tests && cp .build/release/blackout ~/bin/`.
- Manual matrix (user-run): docked lid cycle → internal re-dims, blackout stays on; unplug external mid-session → lid close locks; close undocked → plug display → open → unlock ends session; `-e` → lid close locks with both displays restored.
