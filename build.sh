#!/bin/bash
# Builds ClaudeMeter.app next to this script.
set -euo pipefail

cd "$(dirname "$0")"
APP="ClaudeMeter.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>ClaudeMeter</string>
    <key>CFBundleDisplayName</key>     <string>ClaudeMeter</string>
    <key>CFBundleIdentifier</key>      <string>com.local.claudemeter</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>ClaudeMeter</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <!-- Menu bar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST

swiftc -O \
    -o "$APP/Contents/MacOS/ClaudeMeter" \
    main.swift \
    -framework Cocoa

# Ad-hoc signature keeps Gatekeeper quiet for a locally built binary.
codesign --force --sign - "$APP" 2>/dev/null || true

echo "Built $(pwd)/$APP"
