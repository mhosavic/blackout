# Blackout: instructions for coding agents

Blackout is a macOS menu bar app with a `blackout` command: a hotkey blacks out the screen while the Mac keeps working. The README is the user documentation; this file is what an agent needs to install it for someone.

## Installing it for the user

Needs a Mac with Apple Silicon and macOS 14 or later. No Xcode tools, no Homebrew, no account.

In a clone of this repository:

```bash
./install.sh
```

Without a clone:

```bash
curl -fsSL https://raw.githubusercontent.com/mhosavic/blackout/main/install.sh | bash
```

Both download the latest release and install it. Nothing asks a question and no password is needed, so it runs fine non-interactively. It is safe to run again: it replaces the install in place and keeps the user's settings. It:

- puts the app in `~/Applications/Blackout.app`
- links the command at `~/bin/blackout`
- starts the menu bar app now and at every login

Check it worked:

```bash
~/bin/blackout status
```

The output contains `Menu bar app: running`. If the install stops with an error, its last line says why (wrong Mac, macOS too old, download failed).

## What to tell the user afterwards

- The hotkey is ⌃⌥⌘\ (Control + Option + Command + Backslash). The menu bar icon is an open ring when off and an eclipse when on. Its menu holds the settings, and the hotkey can be changed there.
- `~/bin` is often not on the `PATH`, so the command is `~/bin/blackout` until they add it.
- One optional step needs their password, so they run it themselves rather than you: `~/bin/blackout setup-lid`. It keeps the Mac awake with the lid closed, and writes `/etc/sudoers.d/blackout` allowing only `pmset -a disablesleep 1` and `0`. In Claude Code they can type `! ~/bin/blackout setup-lid` in the prompt. Without it, everything else works and the menu shows a "Lid setup missing" line.
- Updates install themselves: the app checks GitHub once a day and offers the new version in its menu. `~/bin/blackout update` installs it right away.

## Removing it

```bash
~/bin/blackout uninstall    # the app, the command and the login item; keeps settings
./uninstall.sh              # everything, including settings and the sudo rule
```

`uninstall.sh` asks for the password only if `setup-lid` was run. Without a clone, use `curl -fsSL https://raw.githubusercontent.com/mhosavic/blackout/main/uninstall.sh | bash`.

## Working on the code

- Run the tests with `swift run blackout-tests`. `swift test` finds nothing here; the README's Development section says why.
- `make install` builds and installs the checked-out code instead of the latest release (needs the Xcode Command Line Tools).
- `make release VERSION=x.y` publishes a release to GitHub. Only the maintainer runs it.
