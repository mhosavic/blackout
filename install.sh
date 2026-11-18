#!/bin/bash
# Install Blackout from its latest release, or update an existing install:
#
#   curl -fsSL https://raw.githubusercontent.com/mhosavic/blackout/main/install.sh | bash
#
# Downloads Blackout.zip into a temporary folder and runs the app's own
# `blackout install`, the same step `make install` ends with: it puts
# Blackout.app in ~/Applications, links ~/bin/blackout and starts the menu
# bar app at login. No Xcode tools needed.
set -euo pipefail

URL="https://github.com/mhosavic/blackout/releases/latest/download/Blackout.zip"

fail() {
    echo "Error: $*" >&2
    exit 1
}

[ "$(uname -s)" = Darwin ] || fail "Blackout runs on macOS only"
[ "$(uname -m)" = arm64 ] || fail "Blackout needs a Mac with Apple Silicon"
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || fail "Blackout needs macOS 14 (Sonoma) or later"

work=$(mktemp -d -t blackout-install)
trap 'rm -rf "$work"' EXIT

echo "Downloading the latest Blackout..."
curl -fsSL "$URL" -o "$work/Blackout.zip" || fail "could not download $URL"
ditto -x -k "$work/Blackout.zip" "$work" || fail "the download is not a valid zip"
app="$work/Blackout.app"
[ -x "$app/Contents/MacOS/blackout" ] || fail "the download does not contain Blackout.app"
codesign --verify --strict "$app" 2>/dev/null || fail "the downloaded app does not match its signature"

"$app/Contents/MacOS/blackout" install
