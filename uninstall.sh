#!/bin/bash
# Uninstall script for blackout

echo "Uninstalling blackout..."

# Restore settings first if a session is active (toggles blackout off,
# bringing back brightness, volume, and normal sleep)
if [ -f ~/.blackout.state ] && command -v blackout >/dev/null 2>&1; then
    echo "Restoring active blackout session..."
    blackout || true
fi

# Fallback: stop any caffeinate instance the toggle did not clean up
if [ -f ~/.blackout.state ]; then
    PID=$(grep caffeinatePID ~/.blackout.state | grep -o '[0-9]*')
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        echo "Stopping caffeinate process (PID: $PID)..."
        kill "$PID" 2>/dev/null
    fi
fi

# Re-enable system sleep if it was left disabled
if pmset -g | grep -q "SleepDisabled.*1"; then
    echo "Re-enabling system sleep (password may be required)..."
    sudo pmset -a disablesleep 0
fi

# Remove passwordless sudo rule for pmset
if [ -f /etc/sudoers.d/blackout ]; then
    echo "Removing /etc/sudoers.d/blackout (password may be required)..."
    sudo rm -f /etc/sudoers.d/blackout
fi

# Stop and remove daemon
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.blackout.daemon.plist"
if [ -f "$LAUNCH_AGENT" ]; then
    echo "Stopping daemon..."
    launchctl unload "$LAUNCH_AGENT" 2>/dev/null
    rm -f "$LAUNCH_AGENT"
    echo "Removed LaunchAgent"
fi

# Remove daemon directory
if [ -d ~/.blackout ]; then
    rm -rf ~/.blackout
    echo "Removed ~/.blackout directory"
fi

# Remove binary
if [ -f ~/bin/blackout ]; then
    rm -f ~/bin/blackout
    echo "Removed ~/bin/blackout"
fi

if [ -f /usr/local/bin/blackout ]; then
    rm -f /usr/local/bin/blackout 2>/dev/null || sudo rm -f /usr/local/bin/blackout
    echo "Removed /usr/local/bin/blackout"
fi

# Remove state file
if [ -f ~/.blackout.state ]; then
    rm -f ~/.blackout.state
    echo "Removed ~/.blackout.state"
fi

# Clean up old keepawake files if they exist
rm -f ~/bin/keepawake ~/.keepawake.state 2>/dev/null

echo ""
echo "Uninstall complete!"
