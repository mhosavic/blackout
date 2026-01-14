#!/bin/bash
# Uninstall script for blackout

echo "Uninstalling blackout..."

# Stop any running caffeinate instance
if [ -f ~/.blackout.state ]; then
    PID=$(grep caffeinatePID ~/.blackout.state | grep -o '[0-9]*')
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        echo "Stopping caffeinate process (PID: $PID)..."
        kill "$PID" 2>/dev/null
    fi
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
