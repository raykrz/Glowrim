#!/bin/bash
# Builds Glowrim.app using only the Command Line Tools (no Xcode).
set -euo pipefail
cd "$(dirname "$0")"

NAME="Glowrim"
APP="$NAME.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/$NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature so macOS will run it. By default an ad-hoc signature is identified by the
# binary's hash, which changes on every build, so macOS forgets the Audio / Screen Recording
# permissions each time. Pinning the designated requirement to the bundle identifier keeps the
# app's identity the same across rebuilds.
codesign --force --sign - -r="designated => identifier \"dev.glowrim.app\"" "$APP"

echo ""
echo "Built $APP"
echo "Run it with:  open $APP"
