# Blackout 2: menu bar app, saved settings, testable core — design

2026-11-13

## Intent

Blackout is used about 17 times a day (4,709 hotkey toggles in `daemon.log`
since February), almost always through the hotkey. Today there is no way to see
whether it is on, what a session actually did, or to change how the hotkey
behaves: every option is a per-run CLI flag and the hotkey always runs the bare
command.

The goal: an icon in the menu bar that says whether blackout is on, shows
exactly what the current session did and why, and lets every behavior be turned
on or off, with those choices applying to the hotkey, the menu and the CLI
alike. Alongside it, fix what a full read of the code turned up.

## Review of the app as it stands

Found by reading all 1,545 lines and the daemon log.

**Wrong or fragile**

1. *Session logic is untested.* `enable()` and `disable()` live in
   `Sources/blackout/main.swift`, outside `BlackoutCore`. The README says the
   executables are thin; they are not. The 26 tests cover helpers only.
2. *Two toggles can run at once.* Nothing serializes `blackout`. Two runs inside
   the ~1 s enable window both enable: two `caffeinate -d` processes, one of
   them orphaned forever (the display then never sleeps).
3. *The hotkey handler blocks the daemon's main thread* for the whole toggle
   (it reads the child's stdout to EOF). Median toggle is 1 s, worst seen 31 s;
   presses made meanwhile queue up and fire afterwards.
4. *The LaunchAgent is `ProcessType Background`.* launchd throttles CPU and I/O
   for such jobs and their children. The same commands take 0.03 to 0.28 s each
   from a terminal (measured), so the slow tail under load (load average was 15
   to 21 when measured) is most likely this throttling. Unverified until the
   new build logs toggle durations.
5. *Brightness targets `CGMainDisplayID()`,* not the built-in panel. With the
   external set as the main display, or the lid closed, the read fails
   (`rc=1000`, verified on the external), the fallback saves 100 % as the
   "original", and the dim is a no-op.
6. *An unknown argument toggles blackout.* `blackout --staus` turns the screen
   off.
7. *m1ddc is asked about a monitor even when none is plugged in,* on every
   toggle, with no timeout. (Whether to detect a monitor by CoreGraphics
   presence instead of an m1ddc answer was considered and cut, see Review
   rulings.)
8. *The daemon does not use `BlackoutCore`.* It redefines the paths, and its
   install copies only one of the two binaries, so they drift (installed daemon
   is from 31 July, CLI from 13 August).
9. *Notifications cost about 0.2 s per toggle* and are waited on.

**Missing**

10. No visible on/off indicator other than the screen itself.
11. No persistent settings; `PathManager.configFile` is marked "future use".
12. No explicit `on` / `off` (only toggle), which scripts and hooks need.
13. The state file records what to restore, not what was decided and why.

## Goals

- A menu bar icon that shows on/off at a glance and a menu that shows the
  session's details, the settings and any setup problem.
- Settings saved in `~/.blackout/config.json`, honored by hotkey, menu and CLI.
  CLI flags override them for one run, in both directions.
- Session logic in `BlackoutCore` behind one seam, covered by tests that use a
  fake system.
- Fix items 2 to 9 above (item 9: confirmations are sent without waiting for
  `osascript`).
- One install path that keeps the CLI and the menu bar app in step.
- An app icon and a menu bar glyph.

## Non-goals (parked, listed in the final report)

Customizable hotkey; lid setup from the menu (admin password dialog); dimming
several external monitors; low-battery auto-off; auto-off timer; in-process
CoreAudio instead of `osascript` (would save roughly 0.5 s on undocked
toggles); `status --json`; Homebrew packaging.

## Anti-goals

- Any change to the lid-lock rules approved on 2026-08-12 and 2026-08-13:
  the lock is decided at the close edge from live display presence; the lid
  opening onto a lock screen restores brightness; unlocking ends the session
  unconditionally.
- A state file an older binary cannot restore from, or a new binary that
  refuses an older state file. A session is active on the development machine
  during the upgrade.
- A menu that can disagree with reality. It is rebuilt from the files each
  time it opens.
- Changing the default behavior. Defaults equal today's behavior.

## Approaches

**A. Menu bar inside the existing daemon, which keeps shelling out to the CLI
(chosen).** The daemon is already an `NSApplication` with `.accessory` policy
started at login. It gains an `NSStatusItem`; toggling still runs the `blackout`
binary as a child. One implementation of the toggle, crash isolation between UI
and session, the lid watcher keeps re-executing the CLI.

**B. Toggle in-process inside the menu app.** Saves a process spawn (~20 ms)
but gives two entry points into the session logic and couples the lid watcher's
`--lid-watch` re-exec to the app binary. Rejected: no meaningful speed gain,
more ways to go wrong.

**C. SwiftUI `MenuBarExtra` app.** Needs the SwiftUI `App` lifecycle, which
fights the existing `main.swift` (signals, PID file, Carbon hotkey) and gives
nothing an `NSMenu` lacks here. Rejected.

## Design

### Package layout

```
Sources/BlackoutCore/     all logic, no printing in the session path
Sources/blackout/         CLI: parse, call Core, print
Sources/blackout-menu/    menu bar app (renamed from blackout-daemon)
Tests/BlackoutTests/
Resources/Info.plist, Resources/AppIcon.icns
scripts/make-icon.swift   draws the icon, builds the .icns
Makefile                  build, test, bundle, install, uninstall, icon
```

`blackout-menu` depends on `BlackoutCore`. `PathManager` becomes public and the
menu app's duplicate path constants go. The DisplayServices linker flags are
removed from `Package.swift` (see Brightness).

### Settings

`~/.blackout/config.json`, type `Settings` in Core:

| Key | Values | Default | Meaning |
|---|---|---|---|
| `muteAudio` | `auto`, `always`, `never` | `auto` | `auto` mutes only when no external display is online |
| `dimExternal` | bool | `false` | also dim the external display (needs m1ddc) |
| `keepAwakeLidClosed` | bool | `true` | disable lid-close sleep for the session |
| `lockOnLidClose` | bool | `true` | arm the lid watcher |
| `notifications` | bool | `true` | on/off confirmations |

Decoding is per key and lenient: a missing or invalid key takes its default. A
missing or unreadable file yields defaults and is never rewritten until a
setting is changed. Saving is atomic and creates `~/.blackout/`. Settings are
read when a session starts; changing one during a session affects the next
session, and the menu says so.

The "could not re-enable sleep" warning ignores `notifications`: it is the one
message the user must get.

### Session engine

`Session` in Core owns enable, disable and the three lid-watcher handlers. It
talks to the machine only through one protocol, `SystemControls` (brightness,
external display, audio, caffeinate, lid sleep, lock, watcher process,
notifications). `LiveSystem` implements it by delegating to the existing
controllers; tests use a recording fake.

Enable is split so the decision is a pure function:

1. `probe` reads: external display online (CoreGraphics), external luminance
   (m1ddc, nil when unavailable), system sleep already disabled, lock symbol
   available.
2. `SessionPlan.make(settings, probe)` decides, with a reason for each line.
3. `execute` keeps today's order exactly: start caffeinate, disable lid sleep,
   start the watcher, save state, then dim, mute and notify. If saving fails it
   rolls back caffeinate, watcher and lid sleep, as today.

Decision rules (the first three are today's rules, restated):

- Audio is muted when `muteAudio` is `always`, or `auto` with no external
  display online.
- An external display counts as present when CoreGraphics lists one *and*
  m1ddc returns its luminance, which is today's test. m1ddc is only asked when
  CoreGraphics lists one. A listed display that m1ddc cannot read is recorded
  as "unreachable" and treated as absent, as today.
- The external display is dimmed only when `dimExternal` is on and it is
  present. Otherwise it is left on.
- Lid sleep: skipped if the setting is off; left alone if already disabled
  system-wide; otherwise disabled, or reported as "setup missing" when the sudo
  rule is absent.
- The watcher is armed when `lockOnLidClose` is on and the lock symbol exists.

`enable` and `disable` return result values; the CLI prints them. The same
summary lines feed the CLI output and the menu, so wording exists once.

### State file

Stays at `~/.blackout.state` with the same keys. One optional key is added:
`summary`, the four outcomes (audio, external, lid sleep, lid lock) as string
enums. It is decoded with `try?`: an unknown or damaged summary becomes nil and
never prevents a restore. Older binaries ignore the extra key. The menu falls
back to what the legacy keys imply when `summary` is nil.

### Serializing toggles

`SessionLock` takes an exclusive `flock` on `~/.blackout/lock` (opened
`O_CLOEXEC`) around every enable and disable, including the watcher's unlock
path. The direction of a toggle is read *before* waiting for the lock; inside
it the state is read again and the action is idempotent, so two simultaneous
toggles collapse into one action instead of on-then-off. The kernel releases
the lock if the holder dies (the watcher is SIGTERMed by `disable`).

A holder that hangs: the wait is bounded at 10 s. After that, turning *on*
gives up ("another blackout command is still running", exit 1), because
proceeding could start a second caffeinate. Turning *off* proceeds without
the lock, on every path, because getting the screen back must never be
refused and a restore is safe to repeat. If the lock file cannot be opened
at all, both proceed.

Every external command (`osascript`, `m1ddc`, `pmset`, `sudo -n`,
`launchctl`) gets a 10 s timeout and is killed when it expires, so a hung
child cannot hold the lock for long.

### Brightness

`BrightnessController` moves into Core and resolves
`DisplayServicesGetBrightness` / `SetBrightness` with `dlopen` + `dlsym`
(verified working on macOS 27.2), the pattern already used for
`SACLockScreenImmediate`. It targets the built-in display: the first online
display for which `CGDisplayIsBuiltin` is true, falling back to
`CGMainDisplayID()` when none is online. That is a superset of today: with no
built-in online (lid shut) it is the old call exactly, so the lid-open restore
verified in August behaves as before; it differs only when a built-in is
online and is not the main display, where today's code fails. A failed read
still falls back to 100 %, as today: enabling with the lid already shut cannot
know the panel's brightness.

### CLI

```
blackout [toggle|on|off] [overrides]    toggle is the default
blackout status                         session, settings, setup, app
blackout config [<key> <value>]         show or change a setting
blackout install | uninstall | setup-lid
blackout help
```

- Overrides, one run only: `-e/--dim-external`, `--no-dim-external`, `--mute`
  (= `always`), `-m/--no-mute` (= `never`), `--lid`, `-l/--no-lid`, `--lock`,
  `-k/--no-lock`. Giving both forms of one option is an error.
- A corrupt state file is handled as today: cleared, with a message, exit 1.
- `on` when already on and `off` when already off succeed and say so.
- Old spellings keep working: `--install`, `--uninstall`, `--status`,
  `--setup-lid`, `--help`, `-h`, and the internal `--lid-watch`.
- An unknown argument prints an error and exits 2 without touching anything.
- `config` keys: `mute` (`auto|always|never`), `dim-external`, `lid`, `lock`,
  `notifications` (`on|off`).
- Parsing is a pure function in Core returning a command value or an error.

### Menu bar app

Target `blackout-menu`: the existing daemon (signals, PID file, Carbon hotkey,
logger) plus a status item.

Icon: a template image drawn in code. Off is an open ring; on is a solid disc
with a corona arc (an eclipse). It follows the system light/dark menu bar.

Menu, rebuilt from the state file, the settings file and three health checks
every time it opens:

```
Blackout is on · since 14:36
Turn Off                               ⌃⌥⌘\
────────────────────────────────────────
This session
  Built-in display dimmed (was 62%)
  External display left on
  Audio left on (external display connected)
  Awake with the lid closed
  Won't lock while the external display is on
────────────────────────────────────────
Settings (apply the next time Blackout turns on)
  Mute audio                           ▸  Only without an external display ✓ / Always / Never
✓ Keep awake with the lid closed
✓ Lock when the lid closes
  Dim the external display too
✓ Show notifications
────────────────────────────────────────
⚠ Lid setup missing: run "blackout setup-lid" in Terminal
────────────────────────────────────────
Open Log
Quit Blackout
```

The lid-lock line is computed live, because the lock is decided at the close
edge: armed, with an external display online and not dimmed, reads "Won't lock
while the external display is on"; otherwise "Locks when the lid closes".

When off: the first line reads "Blackout is off", the action is "Turn On", and
"This session" is absent. Setup warnings appear only for a setting that is on
and cannot work (lid setup missing; m1ddc missing with "dim external" on; lock
symbol missing).

The menu's content is a pure function in Core, `MenuModel.build(state,
settings, health, now)`, returning item descriptions; the app only renders
them. That makes the menu testable without AppKit.

Behavior:

- The hotkey runs the sibling `blackout toggle`; the menu item runs the
  explicit `blackout on` or `blackout off` it displayed, so a stale menu can
  never do the opposite. Both run on a background queue. While one is in
  flight further presses are ignored and logged; after 60 s the app stops
  waiting, logs it and accepts presses again. Each run logs its duration and
  exit status.
- The app never blocks its main thread on a child. The three health checks
  run in the background (at launch, after each change notification and each
  time the menu closes) and the menu renders the last known values.
- Core posts the Darwin notification `com.blackout.changed` after every state
  save, state clear and settings save. The app listens and redraws the icon.
  It also re-reads the state file every 5 s and when the menu opens, because
  an older watcher, `uninstall.sh` or a manual `rm` clears state without
  posting.
- A second instance (found by bundle identifier, not a PID file that a crash
  can leave stale) exits at once.
- "Quit" exits 0; `KeepAlive.SuccessfulExit = false` keeps it down until the
  next login.

### Bundle and install

`make install`:

1. `swift build -c release`
2. Assemble `.build/Blackout.app`: `Contents/MacOS/blackout-menu`,
   `Contents/MacOS/blackout`, `Contents/Info.plist` (`LSUIElement`, bundle id
   `com.blackout.app`), `Contents/Resources/AppIcon.icns`; ad-hoc codesign.
3. Run the staged CLI's `install`, which: unloads any existing agent, replaces
   `~/Applications/Blackout.app` with its own bundle, points `~/bin/blackout`
   at the bundled CLI (symlink; replaces the old copied binary), removes the
   legacy `~/.blackout/blackout-daemon`, writes the LaunchAgent and loads it.
   Replacing means remove, then copy; never writing through an existing file,
   because a session's watcher may be running from it and macOS kills a signed
   binary whose file changes underneath it.

The LaunchAgent keeps the label `com.blackout.daemon` so the upgrade replaces
the old job in place. `ProgramArguments` points at the bundled `blackout-menu`;
`ProcessType` becomes `Interactive`.

`install` run from outside a bundle (for example `.build/release/blackout`)
stops with "run make install". `uninstall` first turns blackout off if a
session is active and stops if that fails (otherwise nothing would be left to
end the session with), then unloads and removes the agent, the app bundle and
the symlink, and leaves `~/.blackout/config.json` in place.
`uninstall.sh` stays the full removal (sudoers rule, settings) and is updated
for the new paths.

`Bundle.main.executablePath` returns the path the process was started by: the
real path for a helper started inside a bundle, the symlink's path when
started through `~/bin/blackout` (verified). Either re-executes correctly, so
`LidLockController.startWatcher` is unchanged. Anything that asks "which bundle
am I in" resolves symlinks first.

### Icon

`scripts/make-icon.swift` draws the app icon with CoreGraphics (a black disc
eclipsing a warm corona on a near-black rounded square), writes the iconset
and runs `iconutil`. The generated `Resources/AppIcon.icns` is committed so a
build needs no extra step.

## Testing

Unit, in `blackout-tests`, all against the fake system or temp directories:

- `SessionPlan`: every rule above, including the m1ddc-missing and
  already-disabled cases.
- `Session.enable`: order of effects (state saved before the first visible
  change), rollback when the save fails, summary recorded.
- `Session.disable`: restores what the state names and nothing else; stale
  caffeinate PID; does not signal its own PID; the sleep-restore warning.
- Lid handlers: close locks or not per the existing rule; open restores or
  re-dims; unlock always disables.
- `Settings`: defaults, lenient decode, round trip, corrupt file.
- `BlackoutState`: old file without `summary`, file with a damaged `summary`.
- CLI parsing: every command, alias, override, unknown argument.
- `MenuModel`: on, off, legacy state, each warning.
- `SessionLock`: a second holder waits; turning on gives up after the timeout
  and turning off proceeds; two simultaneous enables against a real lock file
  start exactly one caffeinate. Release on process death is a kernel
  guarantee and is not tested.
- LaunchAgent plist content.

End to end, on this Mac:

- `make install` over the running old daemon with a session active; the icon
  appears and shows "on"; the legacy session still turns off correctly.
- One real off/on cycle from the CLI and one via the app, checking brightness,
  the state file, the icon and the logged duration.
- A setting changed in the menu's backing file changes the next session.
- `blackout status`, `blackout config`, an unknown argument.

- The upgrade keeps the old session's caffeinate and watcher alive (`pgrep`
  before and after unloading the old agent).

Not verifiable by me: anything needing the physical lid or the sudo password.
The lid handlers are moved, not rewritten, but the display they address
changed (see Brightness), so the final report carries a three-step owner
checklist: close the lid undocked and open it onto the lock screen; a docked
lid cycle; unlock ends the session.

## Left to the builder

File and type names inside Core beyond those named here, exact help text, and
the exact drawing of the icon.

## Review rulings (2026-11-13)

An adversarial review of this spec found one blocker and eight should-fix
items; all are folded in above. The calls that were not simply "accept":

- **External detection stays as it is today** (CoreGraphics presence was
  proposed, then cut). CoreGraphics also lists a monitor that is switched off,
  Sidecar, virtual displays and dummy plugs; treating those as "in use" would
  leave audio on where today it is muted. Failing toward mute is the safer
  mistake, and it keeps the promise that defaults do not change.
- **Turning off never waits forever and never gives up**; turning on gives up.
  The review wanted every user toggle to give up after the timeout. A refused
  "off" leaves a black screen, so off proceeds.
- **`notifications = false` also silences the "blackout ended" confirmation
  the watcher posts after an unlock** (decision 7 of the 2026-08-12 design).
  It is on by default, so nothing changes unless the setting is turned off;
  the sleep-restore warning is never silenced.
- **The app icon stays** although an `LSUIElement` app's icon is rarely seen:
  a logo was asked for, and it shows in Finder, in System Settings and in the
  README.
- One more fix found while building: `disable` signals the saved PIDs only if
  they are still a `caffeinate` and a `blackout` process. After a reboot the
  numbers can belong to anything.
