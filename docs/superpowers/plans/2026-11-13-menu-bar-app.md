# Blackout 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a menu bar app, saved settings and a tested session engine to blackout, and fix the defects listed in the spec's review.

**Architecture:** All session logic moves into `BlackoutCore` behind one protocol, `SystemControls`, so it runs against a fake in tests. The CLI parses, calls Core and prints. The menu bar app (the old daemon plus an `NSStatusItem`) renders a pure `MenuModel` from Core and toggles by running the sibling CLI binary.

**Tech Stack:** Swift 6.4 in Swift 5 language mode, SwiftPM, AppKit, Carbon hotkeys, IOKit, Swift Testing run through `swift run blackout-tests`, Command Line Tools only (no Xcode).

**Spec:** `docs/superpowers/specs/2026-11-13-menu-bar-app-design.md`

**Execution:** Native, in the main session, five tasks, serial (each task consumes the previous one's interfaces).

## Global Constraints

- Defaults equal today's behavior: `muteAudio = auto`, `dimExternal = false`, `keepAwakeLidClosed = true`, `lockOnLidClose = true`, `notifications = true`.
- Lid-lock rules from the 2026-08-12 spec and its 2026-08-13 revision do not change: lock decided at the close edge by `LidLockController.shouldLockOnLidClose(externalOnline:externalWasDimmed:)`; lid open onto a lock screen restores displays, otherwise re-dims; unlock always ends the session.
- Effect order in enable does not change: caffeinate, lid sleep, watcher, save state, then dim, mute, notify. Save failure rolls back caffeinate, watcher and lid sleep.
- State file stays `~/.blackout.state` with today's keys; the only addition is the optional `summary`, decoded with `try?`.
- Every child process that outlives its parent has stdio on `/dev/null` (caffeinate, watcher, fire-and-forget notifications).
- LaunchAgent label stays `com.blackout.daemon`; `ProcessType` is `Interactive`.
- Tests run with `swift run blackout-tests`; `swift test` does not work here.
- A blackout session may be active on this Mac: no test may read or write `~/.blackout.state`, `~/.blackout/`, or call a real device. Unit tests use temp directories and the fake system.
- No comments on code that is only moved. Match the existing comment style (comments explain why).
- Commits: imperative, one line, the why, under 72 characters.

## Review Focus

1. A state file written by the old binary (no `summary`) is turned off by the new binary: everything restores. Pinned by `disableRestoresFromLegacyStateWithoutSummary` (Task 1).
2. A state file whose `summary` holds a value this binary does not know still restores. Pinned by `damagedSummaryDecodesAsNilAndStateStillLoads` (Task 1).
3. Two toggles started together produce one session, not two caffeinates. Pinned by `enableWhenAlreadyOnDoesNothing` and `secondLockHolderWaitsForTheFirst` (Task 1).
4. `blackout --staus` (any unknown argument) changes nothing. Pinned by `unknownArgumentIsAnError` (Task 2).
5. A `config.json` with one bad value keeps the other values. Pinned by `invalidValueFallsBackToDefaultForThatKeyOnly` (Task 1).

---

### Task 1: Session engine in BlackoutCore

**Files:**
- Create: `Sources/BlackoutCore/Settings.swift`, `SessionSummary.swift`, `SessionPlan.swift`, `SystemControls.swift`, `Session.swift`, `SessionLock.swift`, `ChangeNotifier.swift`
- Move: `Sources/blackout/BrightnessController.swift` to `Sources/BlackoutCore/BrightnessController.swift`
- Modify: `Sources/BlackoutCore/StateManager.swift`, `PathManager.swift`, `NotificationManager.swift`, `Shell.swift`, `Sources/blackout/main.swift`, `Package.swift`
- Test: `Tests/BlackoutTests/FakeSystem.swift`, `SettingsTests.swift`, `SessionPlanTests.swift`, `SessionTests.swift`, `SessionLockTests.swift`, `StateManagerTests.swift`

**Interfaces produced:**

```swift
public enum MutePolicy: String, Codable, CaseIterable { case auto, always, never }

public struct Settings: Equatable {
    public var muteAudio: MutePolicy          // .auto
    public var dimExternal: Bool              // false
    public var keepAwakeLidClosed: Bool       // true
    public var lockOnLidClose: Bool           // true
    public var notifications: Bool            // true
    public init()
    public static var fileURL: URL            // PathManager.configFile, overridable in tests
    public static func load() -> Settings     // defaults on missing/unreadable; lenient per key
    @discardableResult public func save() -> Bool   // atomic, creates the directory, posts ChangeNotifier
    /// keys: mute (auto|always|never), dim-external, lid, lock, notifications (on|off)
    public mutating func set(key: String, value: String) -> Bool
    public static let keys: [String]
    public func value(forKey key: String) -> String?
}

public struct SessionSummary: Codable, Equatable {
    public enum Audio: String, Codable { case muted, leftOnBySetting, leftOnExternalDisplay }
    public enum External: String, Codable { case none, dimmed, leftOn, unreachable }
    public enum LidSleep: String, Codable { case disabled, alreadyDisabled, offBySetting, setupMissing }
    public enum LidLock: String, Codable { case armed, offBySetting, unavailable, watcherFailed }
    public var audio: Audio, external: External, lidSleep: LidSleep, lidLock: LidLock
}

public struct SystemProbe: Equatable {
    public var externalOnline: Bool, externalLuminance: Int?, sleepAlreadyDisabled: Bool, lockAvailable: Bool
}

public struct SessionPlan: Equatable {
    public let muteAudio: Bool, dimExternal: Bool, disableLidSleep: Bool, armLidLock: Bool
    public let summary: SessionSummary        // planned; execute may downgrade lidSleep/lidLock
    public static func make(settings: Settings, probe: SystemProbe) -> SessionPlan
}

public enum NotificationMessage { case enabled, disabled, sleepRestoreFailed }

public protocol SystemControls {
    func brightness() -> Double
    func setBrightness(_ value: Double)
    func isExternalDisplayOnline() -> Bool
    func externalLuminance() -> Int?
    func setExternalLuminance(_ level: Int)
    func volume() -> Int
    func setVolume(_ level: Int)
    func setMuted(_ muted: Bool)
    func startCaffeinate() -> pid_t?
    func stopCaffeinate(pid: pid_t)
    func isCaffeinateRunning(pid: pid_t) -> Bool   // by process name, not mere liveness
    func isSleepDisabled() -> Bool
    func setLidSleepDisabled(_ disabled: Bool) -> Bool
    func isLockAvailable() -> Bool
    func lockScreen()
    func startWatcher() -> pid_t?
    func stopWatcher(pid: pid_t)
    func isWatcherRunning(pid: pid_t) -> Bool
    func notify(_ message: NotificationMessage)
    var ownPID: pid_t { get }
}
public struct LiveSystem: SystemControls { public init() }

public struct Session {
    public init(system: SystemControls)
    public struct EnableReport { public let state: BlackoutState }
    public enum EnableResult { case enabled(EnableReport), alreadyOn, busy, failed(String) }
    public struct DisableReport { public let state: BlackoutState; public let recoveredStaleSession: Bool; public let lidSleepRestoreFailed: Bool }
    public enum DisableResult { case disabled(DisableReport), alreadyOff, corruptState }
    public func enable(settings: Settings) -> EnableResult
    public func disable(notify: Bool) -> DisableResult
    public enum WatcherAction { case keepWatching, stop }
    public func handleLidClose() -> WatcherAction
    public func handleLidOpen(screenLocked: Bool) -> WatcherAction
    public func handleUnlock(notify: Bool) -> WatcherAction     // always .stop
}

public enum SessionLock {
    public static var fileURL: URL                  // PathManager.lockFile
    public static var timeout: TimeInterval         // 10
    public static func withLock<T>(_ body: () -> T) -> T?          // nil = still busy after the timeout; used by enable
    public static func withLockOrProceed<T>(_ body: () -> T) -> T  // used by disable: never refused
}

public enum ChangeNotifier {
    public static let name = "com.blackout.changed"
    public static func post()
    public static func observe(_ handler: @escaping () -> Void)   // delivered on the main queue
}
```

`BlackoutState` gains `public let summary: SessionSummary?` and `StateManager.saveState` gains a `summary:` parameter; `saveState` and `clearState` call `ChangeNotifier.post()`.

- [ ] **Step 1: Settings.** Tests in `SettingsTests.swift` (serialized suite, temp `Settings.fileURL`): `defaultsMatchTodaysBehavior`, `missingFileLoadsDefaults`, `roundTrip`, `corruptFileLoadsDefaultsAndIsNotRewritten`, `invalidValueFallsBackToDefaultForThatKeyOnly` (file `{"muteAudio":"loud","dimExternal":true}` loads `muteAudio == .auto` and `dimExternal == true`), `setParsesEveryKey` (`mute never`, `dim-external on`, `lid off`, `lock off`, `notifications off`), `setRejectsUnknownKeyAndBadValue`. Run, see them fail, implement, see them pass.
- [ ] **Step 2: State summary.** Tests added to `StateManagerTests.swift`: `summaryRoundTrips`, `loadsStateWithoutSummary`, `damagedSummaryDecodesAsNilAndStateStillLoads` (JSON with `"summary": {"audio": "telepathy"}` loads with `summary == nil` and `originalBrightness` intact). Implement the custom `init(from:)`.
- [ ] **Step 3: SessionPlan.** Tests in `SessionPlanTests.swift`, one per rule: `autoMutesWithoutExternal`, `autoKeepsAudioWithExternal` (`.leftOnExternalDisplay`), `neverMuteIsBySetting`, `alwaysMutesEvenWithExternal`, `noExternalIsNone`, `externalLeftOnByDefault`, `dimsExternalWhenAskedAndLuminanceKnown`, `unreachableExternalIsTreatedAsAbsent` (online, luminance nil gives `.unreachable`, `dimExternal == false` and audio muted), `lidSleepOffBySetting`, `lidSleepLeftAloneWhenAlreadyDisabled`, `lidSleepAttemptedOtherwise`, `lockArmedWhenAvailable`, `lockOffBySetting`, `lockUnavailableWithoutSymbol`.
- [ ] **Step 4: BrightnessController into Core** with `dlopen`/`dlsym` and built-in targeting; add `static func builtinDisplay(among ids: [CGDirectDisplayID], isBuiltin: (CGDirectDisplayID) -> Bool, main: CGDirectDisplayID) -> CGDirectDisplayID` with tests `picksTheBuiltinDisplay`, `fallsBackToMainWithoutABuiltin`, and `brightnessSymbolsResolveOnThisMachine`. Remove the DisplayServices linker flags from `Package.swift`.
- [ ] **Step 5: SessionLock and ChangeNotifier.** Tests in `SessionLockTests.swift` (temp lock file): `runsTheBody`, `secondLockHolderWaitsForTheFirst` (a child `/bin/sh` holding `flock` is not available on macOS, so hold the lock from a second file descriptor on a background thread for 0.3 s and assert the body ran after it was released), `givesUpAfterTheTimeout` (timeout 0.2 s, holder never releases, `withLock` returns nil and the body does not run), `proceedVariantRunsAfterTheTimeout`. Both poll `flock(LOCK_EX | LOCK_NB)` every 50 ms until `timeout`; the file is opened `O_CLOEXEC`. `Shell.run` and `Shell.output` kill their child after 10 s; `Shell.spawn` starts one without waiting.
- [ ] **Step 6: FakeSystem and Session.** `FakeSystem` is a class recording every call as a string in `events` and holding settable answers. Tests in `SessionTests.swift` (serialized, temp state and lock files):
  - enable: `enableSavesStateBeforeAnyVisibleChange` (index of `saveState` marker, recorded by checking `StateManager.hasState()` inside the fake's `setBrightness`), `enableFollowsThePlan` (no external: dims, mutes, records volume), `enableLeavesExternalAndAudioWhenDocked`, `enableDimsExternalWhenAsked`, `enableRecordsSetupMissingWhenPmsetFails`, `enableRecordsWatcherFailed`, `enableRollsBackWhenStateCannotBeSaved` (state URL in a missing directory: caffeinate stopped, watcher stopped, lid sleep restored, nothing dimmed, result `.failed`), `enableWhenAlreadyOnDoesNothing`, `simultaneousEnablesStartOneCaffeinate` (two threads, real lock file, one `startCaffeinate`), `enableGivesUpWhileAnotherCommandHoldsTheLock`, `disableProceedsWhileAnotherCommandHoldsTheLock`, `enableSkipsTheDDCProbeWhenNothingIsPluggedIn`, `enableFailsWithoutCaffeinate`, `enableSkipsWhatTheSettingsTurnOff`.
  - disable: `disableRestoresEverythingTheStateNames`, `disableRestoresFromLegacyStateWithoutSummary`, `disableLeavesAudioAloneWhenItWasNotMuted`, `disableDoesNotSignalAStaleCaffeinate`, `disableDoesNotSignalItsOwnPID`, `disableReportsSleepRestoreFailureAndAlwaysNotifies`, `disableWhenOffDoesNothing`, `disableClearsACorruptStateFile`.
  - lid: `lidCloseLocksAndRestoresWithoutExternal`, `lidCloseDoesNothingWhileDocked`, `lidCloseLocksWhenExternalWasDimmed`, `lidOpenOnLockScreenRestoresDisplays`, `lidOpenUnlockedRedims`, `unlockAlwaysEndsTheSession` (external online and undimmed: still disables), `handlersStopWhenTheSessionIsGone`.
- [ ] **Step 7: Rewire `Sources/blackout/main.swift`** to build `Settings.load()`, apply today's four flags, and call `Session`; printing stays in the CLI. `--lid-watch` maps the three handlers; `.stop` exits 0.
- [ ] **Step 8:** `swift build && swift run blackout-tests`; all pass. Commit.

### Task 2: CLI commands

**Files:**
- Create: `Sources/BlackoutCore/CommandLineParser.swift`, `Sources/BlackoutCore/SessionText.swift`
- Modify: `Sources/blackout/main.swift`
- Test: `Tests/BlackoutTests/CommandLineParserTests.swift`, `SessionTextTests.swift`

**Interfaces produced:**

```swift
public struct Overrides: Equatable {
    public var dimExternal: Bool?, mute: Bool?, lid: Bool?, lock: Bool?
    public func applied(to settings: Settings) -> Settings   // mute true = .always, false = .never
}
public enum Command: Equatable {
    case toggle(Overrides), on(Overrides), off, status
    case configShow, configSet(key: String, value: String)
    case install, uninstall, setupLid, lidWatch, help
}
public struct ParseError: Error, Equatable { public let message: String }
public enum CommandLineParser { public static func parse(_ arguments: [String]) -> Result<Command, ParseError> }

public enum SessionText {
    /// Lines describing a running session, for the CLI and the menu
    public static func sessionLines(state: BlackoutState, externalOnline: Bool) -> [String]
    /// "Blackout is on · since 14:36" / "Blackout is off"
    public static func headline(state: BlackoutState?, stateFileExists: Bool, now: Date) -> String
    public static func settingsLines(_ settings: Settings) -> [String]
}
```

Session line wording (exact):

| Outcome | Line |
|---|---|
| always | `Built-in display dimmed (was 62%)` |
| external `.dimmed` | `External display dimmed (was 40%)` |
| external `.leftOn` | `External display left on` |
| external `.unreachable` | `External display not reachable by m1ddc (treated as absent)` |
| audio `.muted` | `Audio muted (was 35%)` |
| audio `.leftOnBySetting` | `Audio left on (setting)` |
| audio `.leftOnExternalDisplay` | `Audio left on (external display connected)` |
| lidSleep `.disabled` | `Awake with the lid closed` |
| lidSleep `.alreadyDisabled` | `Awake with the lid closed (sleep was already disabled system-wide)` |
| lidSleep `.offBySetting` | `Sleeps when the lid closes (setting)` |
| lidSleep `.setupMissing` | `Sleeps when the lid closes (run "blackout setup-lid" once)` |
| lidLock `.armed` | `Locks when the lid closes`; with an external display online and not dimmed: `Won't lock while the external display is on` |
| lidLock `.offBySetting` | `Does not lock when the lid closes (setting)` |
| lidLock `.unavailable` | `Cannot lock when the lid closes (macOS lock call missing)` |
| lidLock `.watcherFailed` | `Cannot lock when the lid closes (watcher failed to start)` |

With `summary == nil` (legacy state) the lines are derived from the legacy keys: external line only when `externalLuminance != nil`; audio `muted` when `originalVolume != nil`, otherwise `Audio left on`; lid sleep `disabled` when `sleepDisabled == true`, otherwise omitted; lid lock `armed` when `lidWatcherPID != nil`, otherwise omitted.

- [ ] **Step 1: Parser tests** `CommandLineParserTests.swift`: `noArgumentsToggles`, `onOffToggleWords`, `overridesBothDirections` (`-e`, `--dim-external`, `--no-dim-external`, `--mute`, `-m`, `--no-mute`, `--lid`, `-l`, `--no-lid`, `--lock`, `-k`, `--no-lock`), `legacySpellings` (`--install`, `--uninstall`, `--status`, `--setup-lid`, `--help`, `-h`, `--lid-watch`), `configShowAndSet`, `configNeedsKeyAndValue`, `unknownArgumentIsAnError`, `overridesWithOffAreAnError`, `twoCommandsAreAnError`, `bothFormsOfOneOptionAreAnError` (`--mute --no-mute`). Implement.
- [ ] **Step 2: SessionText tests**: one assertion per table row, `legacyStateLines`, `headlineOnOffAndStale`. Implement.
- [ ] **Step 3: main.swift** dispatches on `Command`. `status` prints headline, session lines, settings, setup health (lid setup, m1ddc, lock call) and the app status that `--status` printed. `config` prints or sets and prints the new value. Parse error: message to stderr, exit 2. `on` already on and `off` already off print `Blackout is already on/off` and exit 0. Help text rewritten for the new grammar.
- [ ] **Step 4:** build, run tests, run `.build/debug/blackout --bogus; echo $?` (expect 2 and no state change), `.build/debug/blackout help`. Commit.

### Task 3: Menu bar app

**Files:**
- Rename: `Sources/blackout-daemon/` to `Sources/blackout-menu/` (target `blackout-menu`, depends on `BlackoutCore`)
- Create: `Sources/BlackoutCore/MenuModel.swift`, `Sources/BlackoutCore/Health.swift`, `Sources/blackout-menu/StatusItemController.swift`, `MenuBarIcon.swift`, `Toggler.swift`
- Modify: `Sources/blackout-menu/main.swift`, `Package.swift`
- Test: `Tests/BlackoutTests/MenuModelTests.swift`

**Interfaces produced:**

```swift
public struct Health: Equatable {
    public var lidSetupInstalled: Bool, m1ddcInstalled: Bool, lockAvailable: Bool
    public static func check() -> Health
}
public enum MenuAction: Equatable { case turnOn, turnOff, set(key: String, value: String), openLog, quit }
public enum MenuItemModel: Equatable {
    case header(String), info(String), warning(String), separator
    case action(title: String, action: MenuAction, showsHotkey: Bool)
    case toggle(title: String, action: MenuAction, isOn: Bool)
    case submenu(title: String, items: [MenuItemModel])
}
public enum MenuModel {
    public static func build(state: BlackoutState?, stateFileExists: Bool, externalOnline: Bool, settings: Settings, health: Health, now: Date) -> [MenuItemModel]
}
```

- [ ] **Step 1: MenuModel tests**: `offMenuHasTurnOnAndNoSessionSection`, `onMenuHasTurnOffAndSessionLines`, `settingsReflectTheFile` (each toggle's `isOn`, the mute submenu's checked choice), `toggleActionsFlipTheValue` (an on setting carries `.set(key:, value: "off")`), `settingsHeaderMentionsNextSessionOnlyWhileOn`, `warnsWhenLidSetupMissingAndSettingOn`, `noLidWarningWhenSettingOff`, `warnsWhenM1ddcMissingAndDimExternalOn`, `warnsWhenLockCallMissing`, `corruptStateShowsOnWithRestoreHint`. Implement `MenuModel` and `Health`.
- [ ] **Step 2: Toggler**: `final class Toggler` with `func run(_ command: String, completion: @escaping () -> Void)` (`toggle` from the hotkey, `on` or `off` from the menu); runs `Bundle.main.executableURL` sibling `blackout` (falling back to `~/bin/blackout`) on a background queue; ignores calls while one is in flight; stops waiting after 60 s and re-arms; logs `Toggle finished in 0.42s (exit 0)` and the child's output on failure.
- [ ] **Step 3: MenuBarIcon**: `static func image(on: Bool) -> NSImage`, 18 pt template; off is a ring (radius 6.4, width 1.5), on is a disc (radius 5.5) with an arc (radius 7.7, width 1.35, from -35° to 125°).
- [ ] **Step 4: StatusItemController**: owns the `NSStatusItem`; `menuNeedsUpdate` rebuilds from `StateManager`, `Settings.load()` and the cached `Health` (refreshed off the main thread at launch, on each change notification and when the menu closes); renders each `MenuItemModel`; performs `MenuAction`s (`set` goes through `Settings.set` and `save`); `refreshIcon()` on `ChangeNotifier`, after each toggle, when the menu opens and on a 5 s timer.
- [ ] **Step 5: main.swift**: use `PathManager`; exit if another instance with the same bundle identifier is running; hotkey and menu both call the `Toggler`.
- [ ] **Step 6:** build, run tests. Commit.

### Task 4: Icon, bundle, install

**Files:**
- Create: `scripts/make-icon.swift`, `Resources/AppIcon.icns` (generated), `Resources/Info.plist`, `Makefile`, `Sources/BlackoutCore/AppInstaller.swift`
- Delete: `Sources/BlackoutCore/DaemonController.swift`
- Modify: `Sources/BlackoutCore/PathManager.swift`, `Sources/blackout/main.swift`, `uninstall.sh`
- Test: `Tests/BlackoutTests/AppInstallerTests.swift`

**Interfaces produced:**

```swift
public enum AppInstaller {
    public static func launchAgentPlist(programPath: String, logPath: String) -> String
    /// nil when the path is not .../<Name>.app/Contents/MacOS/<exe>
    public static func enclosingBundle(ofExecutable path: String) -> URL?
    public static func install()       // run from a staged bundle's CLI
    public static func uninstall()
    public static func statusLines() -> [String]
}
```

`PathManager` adds `appBundle` (`~/Applications/Blackout.app`), `installedCLI`, `installedMenuApp`, `cliLink` (`~/bin/blackout`), `lockFile`, `legacyDaemonBinary`.

- [ ] **Step 1: Tests**: `plistNamesTheProgramAndIsInteractive` (parse with `PropertyListSerialization`; `Label == com.blackout.daemon`, `ProgramArguments == [path]`, `ProcessType == Interactive`, `RunAtLoad == true`, `KeepAlive.SuccessfulExit == false`), `enclosingBundleFindsTheApp`, `enclosingBundleIsNilOutsideABundle`. Implement.
- [ ] **Step 2: Icon**: `scripts/make-icon.swift <out.icns>` draws the warm eclipse at 1024 px, writes the ten iconset sizes, runs `iconutil -c icns`. Generate and commit `Resources/AppIcon.icns`.
- [ ] **Step 3: Makefile** with `build`, `test`, `bundle` (assembles `.build/Blackout.app`, `codesign --force --sign -`), `install` (`bundle`, then `.build/Blackout.app/Contents/MacOS/blackout install`), `uninstall`, `icon`.
- [ ] **Step 4: install/uninstall** as in the spec (uninstall turns blackout off first and stops if that fails; the bundle and the symlink are replaced by remove-then-create, never written through; bundle lookup resolves symlinks); `uninstall.sh` updated for the app bundle and symlink.
- [ ] **Step 5:** `make bundle`; `codesign --verify .build/Blackout.app`; run tests. Commit.

### Task 5: Docs, install on this Mac, verify, ship

- [ ] **Step 1:** Rewrite `README.md` for the menu bar app, settings, commands, `make install`, file locations.
- [ ] **Step 2:** Whole-branch review by `reviewer` (base `git merge-base origin/main HEAD`); fix findings.
- [ ] **Step 3:** `make install` on this Mac over the running daemon and the live session.
- [ ] **Step 4:** Verify: agent loaded and running from the bundle; a menu bar window owned by `blackout-menu` exists; a screenshot of the menu bar if screen capture is permitted; `blackout status`; one off/on cycle by CLI and the state file's `summary`; a config change reflected in the next session; toggle duration in the log; `pgrep` shows the old session's caffeinate and watcher survive the upgrade. End in the state the Mac started in.
- [ ] **Step 5:** Merge `menu-bar-app` into `main` (fast-forward), push, publish the report artifact, delete the in-flight memory note.
