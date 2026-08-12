# Lock on lid close — design

2026-08-12

## Goal

While blackout is active the Mac stays awake with the lid shut (`pmset -a
disablesleep 1`, see the 2026-07-31 lid-sleep design). That also leaves it
*unlocked*: anyone who opens the lid lands in the live session. Close that hole
— shutting the lid locks the screen, without sleeping the machine and without
stopping any running work.

## Why the obvious levers don't work

Verified on macOS 26.6.1 (build 25G76):

- `CGSession -suspend` — gone. `/System/Library/CoreServices/Menu Extras/User.menu`
  no longer exists on this OS.
- `pmset displaysleepnow`, or starting the screen saver — blackout's own
  `caffeinate -d` holds off display sleep, and the lock grace here is 300s
  (`sysadminctl -screenLock status`), so neither locks immediately.
- A synthetic ⌃⌘Q via CGEvent or AppleScript — needs an Accessibility (TCC)
  grant that neither the CLI nor the daemon has, or should need.
- macOS has no "lid close locks but does not sleep" setting: locking is tied to
  sleep and the screen saver, both of which blackout suppresses on purpose.

So the lid has to be watched directly, and the lock invoked directly.

## Mechanism

Both halves were verified on this machine before writing this spec.

**Detect** — IOKit. `IOServiceAddInterestNotification` on `IOPMrootDomain` with
`kIOGeneralInterest`, filtering for `kIOPMMessageClamshellStateChange`. Public
API (`IOKit/pwr_mgt/IOPM.h`), no entitlement, no TCC prompt. Swift cannot import
the constant — it is a function-like macro,
`iokit_family_msg(sub_iokit_powermanagement, 0x100)` — so hardcode `0xE0034100`
with a comment naming the macro and how to re-derive it (compile the macro in C
and print it). On each message, read `AppleClamshellState` from `IOPMrootDomain`:
a `CFBoolean`, true = closed. Confirmed reading live, flipping No→Yes on a real
lid close.

The header notes this message also fires when `AppleClamshellCausesSleep`
changes, so the watcher must compare against the previous state and act only on
the open→closed edge.

**Lock** — `SACLockScreenImmediate()`, resolved at runtime with
`dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY)`
plus `dlsym`. Confirmed resolvable on 26.6.1. It is the same lock as ⌃⌘Q:
immediate (ignores the 300s grace), Touch ID and Watch unlock still work, and
every process keeps running. Private but long-stable; treated as best-effort, so
its absence degrades to a printed "unavailable" rather than a crash.

**Notice the unlock** — the `com.apple.screenIsUnlocked` distributed
notification, observed through `DistributedNotificationCenter` on the run loop
the watcher is already running. This is what ends the session (decision 6);
lid-open alone must not, since anyone can lift a lid.

## Decisions (approved 2026-08-12)

1. **On by default** when blackout activates, opt out with `--no-lock` / `-k`
   (`-l` is taken by `--no-lid`). Matches the `--no-mute` / `--no-lid`
   default-on pattern and covers the no-args hotkey path, so a closed lid always
   means a locked machine.
2. **Skipped while an external display is left on.** The gate is "is there still
   a usable screen?", not merely "is a monitor attached": skip when an external
   display is detected *and* `--dim-external` was not passed. Docked clamshell
   work (lid shut, working on the monitor) is untouched, while `-e` — dim
   everything, walk away — still locks.
3. **Decided once, at enable time**, from the `ExternalDisplayController.getLuminance()`
   probe `enable()` already runs. Not re-probed when the lid closes: m1ddc talks
   DDC to a display that may be asleep or busy at that moment, and a failed probe
   would read as "no external display" and lock the user out of exactly the setup
   this rule protects.
4. **A detached watcher process per session**, not the daemon: `blackout
   --lid-watch`, spawned by `enable()`, PID recorded in the state file next to
   `caffeinatePID`, SIGTERM'd by `disable()`. It works whether or not the hotkey
   daemon is installed, dies with the session, and reuses the lifecycle pattern
   already proven for caffeinate. Hosting an IOKit source on the daemon's
   existing run loop was rejected: it does nothing for CLI-only use.
5. **Brightness is restored on both lid edges.** `dimScreen()` sets the backlight
   to its floor, and that value persists across a lid cycle — so without this,
   opening the lid means entering a password into a black screen. The open edge
   is the authoritative restore (the panel is powering up, so the write sticks);
   the close edge attempts it too, one call, in case the open notification is
   late. With `-e`, the external display's luminance is restored the same way,
   or the lock screen lands on a monitor dimmed to 0.
6. **Unlocking ends the blackout session.** Brightness is the state indicator —
   0% means on, normal means off — and the lid-open restore has already brightened
   the screen, so leaving blackout active would make that indicator lie. Ending it
   keeps the mapping exact and costs one hotkey to undo. The alternative (stay on,
   dim ends, notification explains) was rejected for exactly that ambiguity.
7. **The watcher reports through notifications, never stdout.** Its stdio is
   `/dev/null` by necessity (decision 4), so `disable()`'s printed warnings would
   vanish. The auto-disable path posts one notification confirming blackout ended,
   and a distinct one carrying `sudo pmset -a disablesleep 0` if the sleep restore
   failed — otherwise the one case the user must know about is the silent one.

## Behavior

**`enable()`**

- Skip the whole feature if `--no-lock`, or if an external display was left on
  (decision 2). Report it in the status block like the audio and lid-sleep lines.
- Otherwise probe `LidLockController.isLockAvailable()` (dlopen + dlsym, no
  call). If the symbol is missing, skip the spawn, print `Lock on lid close:
  unavailable (SACLockScreenImmediate not found)` and carry on — everything else
  still works.
- Spawn `<own executable> --lid-watch` *before* saving state, so its PID goes
  into the state file. Executable path from `Bundle.main.executablePath`.
- **Detach the watcher's stdio to `/dev/null`.** The hotkey daemon captures
  blackout's stdout through a `Pipe` and reads to EOF, so any inherited handle in
  a surviving child deadlocks the daemon for the rest of the session. This is the
  bug already fixed for caffeinate in 72759bd; the watcher must not reintroduce it.
- If `saveState` fails, the existing rollback kills the watcher too, alongside
  caffeinate and lid sleep.
- Status line, one of: `armed` / `skipped (--no-lock)` / `skipped (external
  monitor left on)` / `unavailable (...)` / `failed to start the watcher`.

**`blackout --lid-watch`** — internal mode, handled early alongside
`--setup-lid`, not listed in `--help`.

- Registers the IOKit notification and the unlock observer, runs a CFRunLoop,
  writes nothing to stdout.
- Seeds the previous state from the current clamshell reading at startup, so
  enabling blackout with the lid already shut does not lock immediately.
- Every edge first loads the state file. If it is gone the session ended without
  the watcher being killed (a crash, or a hand-deleted file) — exit rather than
  act on a machine whose blackout is over.
- **Closed edge:** restore `originalBrightness` (and `externalLuminance` if
  `-e` dimmed it), then call `SACLockScreenImmediate()`. Locking again on a later
  close is intentional; locking an already-locked screen is a no-op.
- **Open edge:** restore the same values. This is the restore that matters — it
  is what makes the lock screen readable.
- **Unlock:** run the full `disable()` path, post the confirming notification,
  and exit. Only unlocking does this; an unauthenticated lid-open must not end
  the session.
- No signal handler and no files owned, so the default SIGTERM disposition is
  already the clean exit.

The screen saver can also lock the screen without any lid movement, and
unlocking from that ends the session too. That is consistent with decision 6 —
the screen is bright again, so blackout must be off — and `caffeinate -d` makes
it rare in practice.

**`disable()`**

- If `lidWatcherPID` is present and still running, SIGTERM it. A stale or dead
  PID is ignored, exactly as the caffeinate path already does; the same PID-reuse
  caveat applies and is accepted for the same reason — spawn and kill happen
  inside one session.
- **Skip that kill when the PID is our own.** On the unlock path `disable()` runs
  *inside* the watcher, and SIGTERMing itself mid-function would leave brightness
  and volume unrestored. Calling `disable()` directly, rather than spawning
  `blackout`, is deliberate: bare `blackout` is a toggle, so if the state file had
  already vanished it would *enable* blackout instead of ending it.

Opening the lid does not by itself end the session — it only brightens the
screen so the lock screen can be read. Authentication is what ends it.

**State** — new optional `lidWatcherPID: Int32?` on `BlackoutState`. Optional so
pre-upgrade state files still decode, following the `sleepDisabled` precedent.

## Out of scope

No re-evaluation when displays are plugged or unplugged mid-session (toggle
blackout off and on to re-decide), no lock on idle timeout, and no watcher
liveness reporting in `--status`.

## Files touched

- `Sources/BlackoutCore/LidLockController.swift` (new) — `isLockAvailable()`,
  `lockScreen()`, `isLidClosed() -> Bool?`, `shouldLock(previous:current:)`
  (pure, testable), `startWatcher()`, `stopWatcher(pid:)`, and the watch entry
  point taking an `onLidClose` / `onLidOpen` / `onUnlock` trio.
- `Sources/BlackoutCore/StateManager.swift` — `lidWatcherPID` field and
  `saveState` parameter.
- `Sources/BlackoutCore/NotificationManager.swift` — a notification for the
  auto-disable, and one for a failed sleep restore carrying the manual command.
- `Sources/blackout/main.swift` — `--no-lock` flag, `--lid-watch` branch with the
  three handlers, spawn/kill wiring, the self-kill guard in `disable()`,
  rollback, help text.
- `uninstall.sh` — kill a stray `lidWatcherPID` read from the state file,
  mirroring the existing caffeinate fallback.
- `README.md` — flag row, "what happens when enabled" step, and troubleshooting
  entries: a second `blackout --lid-watch` process is expected; if the lock does
  not fire, check the external-display rule and symbol availability. Note that
  the lock is immediate regardless of the "require password after…" delay.
- `Package.swift` — no change expected: `import IOKit` autolinks and `dlopen`
  needs no linkage. If a build ever fails to link, add `linkedFramework("IOKit")`
  to the `BlackoutCore` target.

## Testing

Automated (`swift run blackout-tests` — the suite is an executable target, so
`swift test` finds nothing):

- `shouldLock` edge table — open→closed locks; closed→open, closed→closed and
  open→open do not. The no-op cases are the point, since the message also fires
  for `AppleClamshellCausesSleep` changes.
- Startup seeding — the first observation never locks, whatever the lid state.
- `BlackoutState` round-trips `lidWatcherPID`, and a state file written without
  the field still decodes.
- `isLockAvailable()` is true on the build machine — an environment assertion
  that fails loudly the day an OS update drops the symbol.

The IOKit callback, the unlock observer, and the lock call itself are not
automatable.

Manual checklist:

1. With `--setup-lid` already done and blackout on, close the lid → screen
   locks, `pmset -g | grep SleepDisabled` still reads `1`, a long-running
   process keeps running. **This is the one unproven assumption in this design:
   that the clamshell message still fires while sleep is disabled.** Everything
   else here was verified before implementation.
2. Open the lid → **the lock screen is readable**, not black. This is the
   decision-5 check; if it fails, the brightness restore is not landing.
3. Unlock → blackout ends: brightness and volume restored, notification shown,
   `pmset -g | grep SleepDisabled` reads `0`, and the watcher is gone
   (`pgrep -f "blackout --lid-watch"` is empty).
4. Open the lid and close it again *without* unlocking → the session survives and
   re-locks; `SleepDisabled` still reads `1`.
5. External display connected and left on at enable → no watcher spawned,
   closing the lid does not lock. With `-e`, the watcher does run, and both
   displays are readable after a lid open.
6. `blackout` again to disable → watcher gone.
7. Toggle twice with ⌃⌥⌘\ → the daemon does not hang (stdio-detach regression).
8. `blackout --no-lock` → no watcher.
