# Blackout

Black out your Mac screen while keeping it awake. One command to toggle on/off.

## Features

- **Blacks out screen** - Dims display to 0%
- **Global hotkey** - Press `⌃⌥⌘\` to toggle from anywhere (daemon required)
- **External monitor support** - Dims external monitors via DDC/CI (requires m1ddc)
- **Smart audio muting** - Mutes audio, but auto-skips when external monitor is detected
- **Prevents sleep** - Keeps your Mac awake (no idle sleep)
- **Toggle on/off** - Same command to enable and disable
- **Remembers state** - Restores your original brightness and volume when disabled
- **macOS notifications** - Visual feedback when toggling
- **Apple Silicon support** - M1/M2/M3/M4 compatible

## Requirements

- macOS 12.0 (Monterey) or later
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
| `-h`, `--help` | Show help message |

### Daemon commands

| Command | Description |
|---------|-------------|
| `--install` | Install hotkey daemon (runs at login) |
| `--uninstall` | Remove hotkey daemon |
| `--status` | Show daemon status and recent logs |

### What happens when enabled

1. Your current brightness, volume, and external display luminance are saved
2. Screen dims to 0%
3. External monitors dim to minimum (if m1ddc installed)
4. Audio is muted (skipped if external monitor detected)
5. `caffeinate` prevents idle sleep
6. Notification confirms activation

### What happens when disabled

1. Original brightness is restored
2. External monitor brightness is restored
3. Audio is unmuted and volume restored (if it was muted)
4. Sleep prevention is removed
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
│                        blackout                               │
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
│  • Dim built-in to 0%                                        │
│  • Dim external (m1ddc)                                      │
│  • Mute audio*                                               │
│                                                              │
│  *Audio auto-skipped when external monitor detected          │
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

### Screen stays black after disable

This can happen if blackout crashes. To recover:

```bash
# Restore brightness manually
brightness 1.0

# Or use System Preferences keyboard shortcut
# Press F2 (or fn+F2) repeatedly
```

## Limitations

Cannot prevent sleep from:
- Closing laptop lid
- Apple menu → Sleep
- Low battery
- Thermal emergency

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

# 4. Remove binary and state
rm -f ~/bin/blackout
rm -f ~/.blackout.state
```

## License

MIT
