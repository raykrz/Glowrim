#!/bin/bash
# Builds a universal Glowrim.app and zips it for a GitHub release: dist/Glowrim-<version>.zip
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)"
UNIVERSAL=1 ./build.sh

mkdir -p dist
ZIP="dist/Glowrim-$VERSION.zip"
rm -f "$ZIP"
# ditto keeps the code signature and resource forks intact (plain zip can break them).
ditto -c -k --keepParent Glowrim.app "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
echo ""
echo "Packaged $ZIP"
