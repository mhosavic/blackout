# Blackout

Black out your Mac screen while keeping it awake. One command to toggle on/off.

## Features

- **Blacks out screen** - Dims display to 0%
- **External monitor support** - Dims external monitors via DDC/CI (requires m1ddc)
- **Mutes audio** - Silences system audio
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

## Usage

```bash
# Enable (blacks out screen, prevents sleep)
blackout

# Disable (restores brightness, allows sleep)
blackout
```

Run the same command to toggle on/off.

### What happens when enabled

1. Your current brightness, volume, and external display luminance are saved
2. Screen dims to 0%
3. External monitors dim to minimum (if m1ddc installed)
4. Audio is muted
5. `caffeinate` prevents idle sleep
6. Notification confirms activation

### What happens when disabled

1. Original brightness is restored
2. External monitor brightness is restored
3. Audio is unmuted and volume restored
4. Sleep prevention is removed
5. Notification confirms deactivation

## Keyboard Shortcut

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
│    • Save brightness, volume & ext display  │
│    • Start caffeinate -d                    │
│    • Dim built-in screen to 0%              │
│    • Dim external monitors (via m1ddc)      │
│    • Mute audio                             │
│                                             │
│  ON → Disable:                              │
│    • Restore all saved settings             │
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
