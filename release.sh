#!/bin/bash
# Builds the downloadable ClaudeMeter.zip for a GitHub release.
#
# It's ad-hoc signed, not notarized (that needs a paid Apple Developer account),
# so macOS blocks the first launch until the user clicks "Open Anyway" in
# System Settings → Privacy & Security. The README walks through that.
#
# Usage:  ./release.sh        → dist/ClaudeMeter.zip
#         gh release create vX.Y.Z dist/ClaudeMeter.zip
set -euo pipefail

cd "$(dirname "$0")"
UNIVERSAL=1 ./build.sh

mkdir -p dist
rm -f dist/ClaudeMeter.zip
# ditto, not zip: it keeps the bundle's signature and metadata intact.
ditto -c -k --keepParent ClaudeMeter.app dist/ClaudeMeter.zip

lipo -archs ClaudeMeter.app/Contents/MacOS/ClaudeMeter
echo "Built $(pwd)/dist/ClaudeMeter.zip"
