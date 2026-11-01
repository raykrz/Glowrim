#!/bin/bash
# Builds Glowrim.app using only the Command Line Tools (no Xcode).
set -euo pipefail
cd "$(dirname "$0")"

NAME="Glowrim"
APP="$NAME.app"

if [ "${UNIVERSAL:-0}" = "1" ]; then
    # One app that runs natively on both Apple Silicon and Intel Macs.
    BINS=()
    for arch in arm64 x86_64; do
        swift build -c release --triple "$arch-apple-macosx14.2"
        BINS+=("$(swift build -c release --triple "$arch-apple-macosx14.2" --show-bin-path)/$NAME")
    done
    BIN=".build/$NAME-universal"
    lipo -create "${BINS[@]}" -output "$BIN"
else
    swift build -c release
    BIN="$(swift build -c release --show-bin-path)/$NAME"
fi

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
