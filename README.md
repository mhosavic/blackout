# Blackout

Black out your Mac screen while keeping it awake. One command to toggle on/off.

## Features

- **Blacks out screen** - Dims display to 0%
- **Prevents sleep** - Keeps your Mac awake (no idle sleep)
- **Toggle on/off** - Same command to enable and disable
- **Remembers brightness** - Restores your original brightness when disabled
- **macOS notifications** - Visual feedback when toggling
- **Apple Silicon support** - M1/M2/M3/M4 compatible

## Requirements

- macOS 12.0 (Monterey) or later
- Xcode Command Line Tools (`xcode-select --install`)

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

## Usage

```bash
# Enable (blacks out screen, prevents sleep)
blackout

# Disable (restores brightness, allows sleep)
blackout
```

Run the same command to toggle on/off.

### What happens when enabled

1. Your current brightness is saved
2. Screen dims to 0%
3. `caffeinate` prevents idle sleep
4. Notification confirms activation

### What happens when disabled

1. Original brightness is restored
2. Sleep prevention is removed
3. Notification confirms deactivation

## Keyboard Shortcut

### iTerm2

1. **Settings** → **Keys** → **Key Bindings**
2. Click **+** to add a new binding
3. Set your shortcut (e.g., `Cmd+Shift+\`)
4. Action: **Run Command**
5. Command: `~/bin/blackout`

### Shortcuts app (other apps)

1. Open **Shortcuts** app
2. Create new shortcut → Add **Run Shell Script**
3. Enter: `~/bin/blackout`
4. Add keyboard shortcut via shortcut settings

## How It Works

```
┌─────────────────────────────────────────────┐
│                 blackout                     │
├─────────────────────────────────────────────┤
│  Toggle based on ~/.blackout.state          │
│                                             │
│  OFF → Enable:                              │
│    • Save current brightness                │
│    • Start caffeinate -d                    │
│    • Dim screen to 0%                       │
│                                             │
│  ON → Disable:                              │
│    • Restore saved brightness               │
│    • Kill caffeinate                        │
└─────────────────────────────────────────────┘
```

### Limitations

Cannot prevent sleep from:
- Closing laptop lid
- Apple menu → Sleep
- Low battery
- Thermal emergency

## Uninstall

```bash
./uninstall.sh
```

Or manually:

```bash
pkill -f "caffeinate -d"
rm -f ~/bin/blackout
rm -f ~/.blackout.state
```

## License

MIT
