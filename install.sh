#!/bin/bash
# Installs Sprout to ~/Applications and launches it.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/andy-watanabe/sprout/main/install.sh | bash
# or, from a clone of this repo:
#   ./install.sh
set -euo pipefail

REPO_URL="https://github.com/andy-watanabe/sprout.git"
INSTALL_DIR="$HOME/Applications"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "error: Swift compiler not found." >&2
    echo "Install the Xcode Command Line Tools first:  xcode-select --install" >&2
    exit 1
fi

# Running via curl | bash lands in some unrelated directory with no source
# nearby, so clone into a temp dir. Running ./install.sh from a checkout
# builds in place.
if [ -f "main.swift" ] && [ -f "build.sh" ]; then
    WORKDIR="$(pwd)"
    CLEANUP=false
else
    WORKDIR="$(mktemp -d)"
    CLEANUP=true
    echo "Cloning sprout into a temporary directory..."
    git clone --depth 1 "$REPO_URL" "$WORKDIR/sprout" >/dev/null
    WORKDIR="$WORKDIR/sprout"
fi

(
    cd "$WORKDIR"
    ./build.sh
)

mkdir -p "$INSTALL_DIR"
pkill -x Sprout 2>/dev/null || true

# Sprout used to be ClaudeMeter. Replace it, keeping Start at Login if it was on.
OLD_AGENT="$HOME/Library/LaunchAgents/com.local.claudemeter.plist"
NEW_AGENT="$HOME/Library/LaunchAgents/com.local.sprout.plist"
if [ -d "$INSTALL_DIR/ClaudeMeter.app" ] || [ -f "$OLD_AGENT" ]; then
    echo "Replacing ClaudeMeter with Sprout..."
    pkill -x ClaudeMeter 2>/dev/null || true
    if [ -f "$OLD_AGENT" ]; then
        rm -f "$OLD_AGENT"
        cat > "$NEW_AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>             <string>com.local.sprout</string>
    <key>ProgramArguments</key>  <array><string>$INSTALL_DIR/Sprout.app/Contents/MacOS/Sprout</string></array>
    <key>RunAtLoad</key>         <true/>
</dict>
</plist>
PLIST
    fi
    rm -rf "$INSTALL_DIR/ClaudeMeter.app"
    defaults delete com.local.claudemeter 2>/dev/null || true
fi

rm -rf "$INSTALL_DIR/Sprout.app"
cp -R "$WORKDIR/Sprout.app" "$INSTALL_DIR/"

if [ "$CLEANUP" = true ]; then
    rm -rf "$(dirname "$WORKDIR")"
fi

echo "Installed to $INSTALL_DIR/Sprout.app"
open "$INSTALL_DIR/Sprout.app"
echo "Running now. Click the menu bar icon → Start at Login to keep it running after reboot."
