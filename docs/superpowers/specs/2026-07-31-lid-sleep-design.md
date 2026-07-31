# Lid-close sleep prevention — design

2026-07-31

## Goal

While blackout is active, closing the MacBook lid must not sleep the machine, so
background processes keep running. Restored exactly when blackout is toggled off.

## Why not caffeinate

Blackout already spawns `caffeinate -d`, but lid close is a clamshell sleep
request that ignores all caffeinate/IOKit idle-sleep assertions. The only lever
that reaches it is `sudo pmset -a disablesleep 1` (verified: shows as
`SleepDisabled 1` in `pmset -g`; Apple menu Sleep greys out). The setting is
global and persists across reboots, so cleanup must be reliable.

## Decisions (approved 2026-07-31)

1. **Always on when blackout activates**, with a `--no-lid` / `-l` opt-out flag —
   matches the `--no-mute` / `--no-external` default-on pattern and keeps the
   no-args hotkey-daemon path working.
2. **One-time sudoers rule** via a new `blackout --setup-lid` subcommand (run
   interactively once). Writes `/etc/sudoers.d/blackout` allowing passwordless
   execution of exactly two commands: `/usr/bin/pmset -a disablesleep 1` and
   `/usr/bin/pmset -a disablesleep 0`. Nothing else gains privileges.

## Behavior

- `enable()`: unless `--no-lid`, first read `pmset -g` — if `SleepDisabled` is
  already 1 (user set it themselves), record that we did NOT set it and leave it
  alone on disable. Otherwise run `sudo -n /usr/bin/pmset -a disablesleep 1`.
  - `sudo -n` (never prompts): if it fails (sudoers rule not installed), print
    "Lid sleep: unavailable (run: blackout --setup-lid)" and continue — the rest
    of blackout still works. Success/skip is reported like the audio line.
- State: new optional `sleepDisabled: Bool?` field on `BlackoutState` (optional
  so pre-upgrade state files still decode). True only if *we* set it.
- `disable()`: if `sleepDisabled == true`, run `sudo -n /usr/bin/pmset -a
  disablesleep 0`; on failure print a loud warning with the manual reset command.
- `--setup-lid`: builds the sudoers line for the current user, validates with
  `visudo -c -f` on a temp file, installs root-owned mode 0440 via one
  interactive `sudo`. Idempotent.
- `uninstall.sh`: also runs `sudo pmset -a disablesleep 0` and removes
  `/etc/sudoers.d/blackout`.
- README: flag table row, setup section, file-locations row, troubleshooting
  entry, and a prominent warning: lid closed in a bag = machine fully awake
  (heat + battery drain).

## Files touched

`Sources/blackout/SleepController.swift` (pmset wrappers + SleepDisabled probe),
`Sources/blackout/StateManager.swift` (state field),
`Sources/blackout/main.swift` (flag, subcommand, enable/disable wiring, help),
`uninstall.sh`, `README.md`.

## Testing

No test suite exists in this repo (noted; a `swift-testing` target over
StateManager would be the first candidate). Verification: `swift build -c
release`, run toggle on/off checking `pmset -g | grep SleepDisabled`, verify
graceful-skip path before `--setup-lid` is run, verify old state file decodes.
