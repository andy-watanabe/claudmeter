#!/bin/bash
# Builds Sprout.app next to this script.
set -euo pipefail

cd "$(dirname "$0")"
APP="Sprout.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Sprout</string>
    <key>CFBundleDisplayName</key>     <string>Sprout</string>
    <key>CFBundleIdentifier</key>      <string>com.local.sprout</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>Sprout</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <!-- Menu bar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST

# UNIVERSAL=1 builds for both Apple Silicon and Intel, for the downloadable
# release. A local build only needs this Mac's architecture.
if [ "${UNIVERSAL:-0}" = 1 ]; then
    for arch in arm64 x86_64; do
        swiftc -O -target "$arch-apple-macos13.0" \
            -o "$APP/Contents/MacOS/Sprout-$arch" \
            main.swift \
            -framework Cocoa
    done
    lipo -create -output "$APP/Contents/MacOS/Sprout" \
        "$APP/Contents/MacOS/Sprout-arm64" "$APP/Contents/MacOS/Sprout-x86_64"
    rm "$APP/Contents/MacOS/Sprout-arm64" "$APP/Contents/MacOS/Sprout-x86_64"
else
    swiftc -O \
        -o "$APP/Contents/MacOS/Sprout" \
        main.swift \
        -framework Cocoa
fi

# Ad-hoc signature keeps Gatekeeper quiet for a locally built binary.
codesign --force --sign - "$APP" 2>/dev/null || true

echo "Built $(pwd)/$APP"
