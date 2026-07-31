# Blackout

Black out your Mac screen while keeping it awake. One command to toggle on/off.

## Features

- **Blacks out screen** - Dims display to 0%
- **Global hotkey** - Press `⌃⌥⌘\` to toggle from anywhere (daemon required)
- **External monitor support** - Dims external monitors via DDC/CI (requires m1ddc)
- **Smart audio muting** - Mutes audio, but auto-skips when external monitor is detected
- **Prevents sleep** - Keeps your Mac awake (no idle sleep)
- **Survives lid close** - Processes keep running with the lid shut (after one-time `--setup-lid`)
- **Toggle on/off** - Same command to enable and disable
- **Remembers state** - Restores your original brightness and volume when disabled
- **macOS notifications** - Visual feedback when toggling
- **Apple Silicon support** - M1/M2/M3/M4 compatible

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode Command Line Tools (`xcode-select --install`)
- Optional: [m1ddc](https://github.com/waydabber/m1ddc) for external monitor support (`brew install m1ddc`)

## Installation

### Build from source

```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/blackout.git
cd blackout

# Build
swift build -c release

# Install to ~/bin (create if needed)
mkdir -p ~/bin
cp .build/release/blackout ~/bin/

# Add ~/bin to PATH (if not already)
echo 'export PATH=$HOME/bin:$PATH' >> ~/.zshrc
source ~/.zshrc
```

### Enable global hotkey

```bash
blackout --install
```

This installs a lightweight background daemon that listens for `⌃⌥⌘\` globally. The daemon starts automatically at login.

### Enable lid-close sleep prevention (optional, one-time)

```bash
blackout --setup-lid
```

macOS puts the Mac to sleep when the lid closes, even with `caffeinate` running — only `sudo pmset -a disablesleep` can override it, and that needs root. This one-time setup asks for your password and writes `/etc/sudoers.d/blackout`, allowing exactly two commands to run without a password:

```
pmset -a disablesleep 1
pmset -a disablesleep 0
```

Nothing else is granted. After setup, every blackout activation disables lid-close sleep and every deactivation restores it — including via the hotkey. Without setup, blackout still works and simply reports `Lid sleep: unavailable`.

> **Warning:** while blackout is active, closing the lid keeps the Mac fully awake — including in a backpack. Watch for heat and battery drain, and toggle blackout off before packing it away.

## Usage

```bash
# Toggle blackout on/off
blackout
```

Run the same command to toggle on/off.

### Options

| Flag | Description |
|------|-------------|
| `-n`, `--no-external` | Skip dimming external monitors |
| `-m`, `--no-mute` | Skip muting audio |
| `-l`, `--no-lid` | Skip disabling lid-close sleep |
| `-h`, `--help` | Show help message |

### Daemon commands

| Command | Description |
|---------|-------------|
| `--install` | Install hotkey daemon (runs at login) |
| `--uninstall` | Remove hotkey daemon |
| `--status` | Show daemon status and recent logs |
| `--setup-lid` | One-time setup for lid-close sleep prevention |

### What happens when enabled

1. Your current brightness, volume, and external display luminance are saved
2. Screen dims to 0%
3. External monitors dim to minimum (if m1ddc installed)
4. Audio is muted (skipped if external monitor detected)
5. `caffeinate` prevents idle sleep
6. Lid-close sleep is disabled (if `--setup-lid` was run; skipped if sleep was already disabled system-wide)
7. Notification confirms activation

### What happens when disabled

1. Original brightness is restored
2. External monitor brightness is restored
3. Audio is unmuted and volume restored (if it was muted)
4. Sleep prevention is removed and lid-close sleep re-enabled
5. Notification confirms deactivation

## Keyboard Shortcut

### Native daemon (recommended)

```bash
blackout --install
```

Press **`⌃⌥⌘\`** (Control + Option + Command + Backslash) to toggle blackout from anywhere.

The daemon runs silently in the background (~5MB RAM, 0% CPU when idle) and starts automatically at login.

To check status or troubleshoot:

```bash
blackout --status
```

### Alternative: macOS Shortcuts app

If you prefer not to use the daemon:

1. Open **Shortcuts** app
2. Create new shortcut → Add **Run Shell Script**
3. Enter: `~/bin/blackout`
4. Add keyboard shortcut via shortcut settings

## How It Works

```
┌──────────────────────────────────────────────────────────────┐
│                        blackout                              │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  CLI Mode                      Daemon Mode                   │
│  ─────────                     ───────────                   │
│  $ blackout                    ⌃⌥⌘\ hotkey                   │
│       │                             │                        │
│       └──────────┬──────────────────┘                        │
│                  ▼                                           │
│         Toggle based on                                      │
│         ~/.blackout.state                                    │
│                  │                                           │
│     ┌────────────┴────────────┐                              │
│     ▼                         ▼                              │
│  OFF → Enable:             ON → Disable:                     │
│  • Save brightness,        • Restore all                     │
│    volume & ext display      saved settings                  │
│  • Start caffeinate -d     • Kill caffeinate                 │
│  • Disable lid sleep**     • Re-enable lid sleep             │
│  • Dim built-in to 0%                                        │
│  • Dim external (m1ddc)                                      │
│  • Mute audio*                                               │
│                                                              │
│  *Audio auto-skipped when external monitor detected          │
│  **After one-time 'blackout --setup-lid'                     │
└──────────────────────────────────────────────────────────────┘
```

## File Locations

| File | Purpose |
|------|---------|
| `~/.blackout.state` | Stores session state (brightness, volume, PID) |
| `~/.blackout/` | Daemon directory |
| `~/.blackout/blackout-daemon` | Daemon binary |
| `~/.blackout/daemon.log` | Daemon log file |
| `~/.blackout/daemon.pid` | Daemon process ID |
| `~/Library/LaunchAgents/com.blackout.daemon.plist` | LaunchAgent for auto-start |
| `/etc/sudoers.d/blackout` | Passwordless rule for `pmset disablesleep` (from `--setup-lid`) |

## Troubleshooting

### Hotkey not working

1. Check if daemon is running:
   ```bash
   blackout --status
   ```

2. If not running, try reinstalling:
   ```bash
   blackout --uninstall
   blackout --install
   ```

3. Grant accessibility permissions if prompted (System Settings → Privacy & Security → Accessibility)

### Daemon not starting at login

1. Check LaunchAgent is installed:
   ```bash
   ls ~/Library/LaunchAgents/com.blackout.daemon.plist
   ```

2. Check system logs:
   ```bash
   cat ~/.blackout/daemon.log
   ```

3. Manually load the daemon:
   ```bash
   launchctl load ~/Library/LaunchAgents/com.blackout.daemon.plist
   ```

### External monitor not dimming

1. Install m1ddc:
   ```bash
   brew install m1ddc
   ```

2. Verify your monitor supports DDC/CI (most do, but some gaming monitors disable it)

3. Test m1ddc directly:
   ```bash
   m1ddc display list
   m1ddc set luminance 50
   ```

### Screen stays black after a crash

Just run `blackout` again. If a saved session exists — even one whose
caffeinate process died in a crash or reboot — blackout restores from it
instead of re-enabling. If the state file itself was lost:

```bash
# Restore brightness manually
brightness 1.0

# Or use the keyboard: press F2 (or fn+F2) repeatedly
```

### Mac won't sleep after a crash

If blackout crashed while active with lid-sleep prevention on, sleep stays disabled (the setting survives reboots). Check and reset with:

```bash
pmset -g | grep SleepDisabled   # 1 = sleep disabled
sudo pmset -a disablesleep 0
```

### Lid sleep shows "unavailable"

Run the one-time setup:

```bash
blackout --setup-lid
```

## Limitations

Cannot prevent sleep from:
- Closing laptop lid *before* `--setup-lid` has been run
- Apple menu → Sleep (greyed out while lid sleep is disabled)
- Low battery
- Thermal emergency

## Development

```bash
swift build                 # debug build
swift run blackout-tests    # run the test suite
swift build -c release      # release build
```

Code is organized as a `BlackoutCore` library (all logic), with thin
`blackout` and `blackout-daemon` executables on top. Tests use
[Swift Testing](https://developer.apple.com/documentation/testing) via the
dedicated `blackout-tests` runner, because `swift test` cannot execute Swift
Testing bundles with Command Line Tools alone (no full Xcode required this way).

## Uninstall

Run the uninstall script:

```bash
./uninstall.sh
```

Or manually:

```bash
# 1. Stop daemon and remove LaunchAgent
launchctl unload ~/Library/LaunchAgents/com.blackout.daemon.plist 2>/dev/null
rm -f ~/Library/LaunchAgents/com.blackout.daemon.plist

# 2. Remove daemon files
rm -rf ~/.blackout

# 3. Stop any active blackout session
pkill -f "caffeinate -d"

# 4. Re-enable sleep and remove the sudoers rule (if --setup-lid was used)
sudo pmset -a disablesleep 0
sudo rm -f /etc/sudoers.d/blackout

# 5. Remove binary and state
rm -f ~/bin/blackout
rm -f ~/.blackout.state
```

## License

MIT
