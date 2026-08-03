# Leave external monitors untouched — design

2026-08-02

## Goal

With lid-sleep prevention in place, the new workflow is: activate blackout,
close the lid, keep working on the external monitor. Dimming the external
(today's default) fights that — it blacks out the only usable screen.

## Decisions (approved 2026-08-02)

1. **External detected → leave it untouched by default.** Only the built-in
   screen dims; audio already auto-stays-on when an external is present.
   The old dim-everything behavior moves behind a new `--dim-external` / `-e`
   flag for terminal use. `--no-external` / `-n` is removed — with the new
   default there is nothing for it to skip.
2. **Lid-sleep prevention stays unconditional** (minus `--no-lid`). Native
   clamshell mode only covers AC power; keeping the pmset override also
   covers battery, and it is invisible because toggle-off always restores it.

## Behavior

- No external connected: unchanged (dim, mute, caffeinate, lid sleep).
- External connected (default): dim built-in only, keep audio, keep awake,
  disable lid sleep. Print "External display: left on (--dim-external to dim)".
  No luminance is saved, so disable() has nothing external to restore.
- External connected + `--dim-external`: previous behavior — save luminance,
  dim external, restore on toggle-off.

## Files touched

`Sources/blackout/main.swift` (flag swap, enable() wiring, help),
`README.md` (features, options table, what-happens lists, diagram,
troubleshooting). Core library and daemon unchanged; hotkey path gets the
new default automatically because it passes no flags.

## Testing

Suite unchanged (decision lives in main.swift). Verify: build, run tests,
toggle on/off checking the printed reasons, push, reinstall CLI binary.
