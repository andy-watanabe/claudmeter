#!/bin/bash
# Installs ClaudeMeter to ~/Applications and launches it.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/andy-watanabe/claudmeter/main/install.sh | bash
# or, from a clone of this repo:
#   ./install.sh
set -euo pipefail

REPO_URL="https://github.com/andy-watanabe/claudmeter.git"
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
    echo "Cloning claudmeter into a temporary directory..."
    git clone --depth 1 "$REPO_URL" "$WORKDIR/claudmeter" >/dev/null
    WORKDIR="$WORKDIR/claudmeter"
fi

(
    cd "$WORKDIR"
    ./build.sh
)

mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/ClaudeMeter.app"
cp -R "$WORKDIR/ClaudeMeter.app" "$INSTALL_DIR/"

if [ "$CLEANUP" = true ]; then
    rm -rf "$(dirname "$WORKDIR")"
fi

echo "Installed to $INSTALL_DIR/ClaudeMeter.app"
open "$INSTALL_DIR/ClaudeMeter.app"
echo "Running now. Click the menu bar icon → Start at Login to keep it running after reboot."
