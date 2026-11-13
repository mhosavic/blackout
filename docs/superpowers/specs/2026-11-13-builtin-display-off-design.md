# Turn the built-in display off when docked — design

2026-11-13

## Why

With the lid open and an external monitor in use, blackout dims the built-in
panel to black but it stays the main display. macOS shows notification banners
on the main display, so they land on a screen that cannot be seen.

## What was tried first, and why it was dropped

Making the external monitor the main display (`CGConfigureDisplayOrigin`).
Trial on macOS 27.2: it works and reverts exactly, but macOS moves the desktops
with the main display. The terminal windows went to the built-in screen and the
browser came to the external one, the opposite of the goal.

## What is built

A setting, `builtin-off`, off by default: "Turn the built-in display off when
docked". When it is on and an external display is in use, blackout switches the
built-in display off instead of dimming it. To macOS that is a closed lid: the
external becomes the main display, its windows stay put, windows from the
built-in move over, and banners appear there. Turning blackout off switches the
built-in back on; macOS puts its windows back.

Trial on macOS 27.2 (`CGSConfigureDisplayEnabled`, an undocumented CoreGraphics
call, resolved at runtime like the brightness and lock calls): off in 0.2 s,
external main at 0,0 with its windows in place, back on with the original
layout (`-210,-1080`) and windows.

## Rules

- Applies only when the setting is on, an external display is present (the
  same test as for audio: listed by macOS and readable by m1ddc) and "dim the
  external display too" is off. Otherwise the built-in is dimmed as before.
- If this macOS does not expose the call, or it fails, the built-in is dimmed
  instead and the session says so.
- **Never the last screen.** The built-in is not switched off unless another
  display is online at that moment.
- **Monitor unplugged mid-session:** the built-in is switched back on and
  dimmed (blackout is still on, as it would be undocked). Plugged in again: off
  again. This is the session watcher's job, so in this mode the watcher runs
  even when "lock when the lid closes" is off; in that case it does not lock
  and an unlock does not end the session, exactly as when no watcher ran. The
  menu bar app runs the same check as a second safety net.
- **Lid opened while docked:** macOS brings the built-in back; it is switched
  off again (today: re-dimmed).
- **Lid opened onto a lock screen:** the built-in is switched on and its
  brightness restored, so the lock screen is readable, as today.
- The lid-lock rules themselves do not change.

## State

Three optional keys are added to `~/.blackout.state`: `builtinOff` (the
session is in this mode), `builtinDisplayID` (the display to switch back on;
written before the display is switched off, because once it is off it is no
longer listed) and `lidLockArmed`. A state file without `lidLockArmed` comes
from a version where a watcher always meant the lock was armed, and is read
that way. Restoring never depends on the summary.

## Not verifiable by me

Anything needing the lid or a cable pulled: the owner checks unplugging the
monitor mid-session and a docked lid cycle.
