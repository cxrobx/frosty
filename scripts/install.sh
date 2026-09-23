#!/bin/sh
# Build a Release Frosty and install it into /Applications, replacing a running copy.
#
# Set FROSTY_APP_DIR to install somewhere else, e.g. ~/Applications on a managed Mac
# where /Applications is not writable.
#
# Set FROSTY_SIGN_IDENTITY to a signing identity (security find-identity -v -p codesigning)
# to re-sign the installed app with it. macOS ties an ad-hoc signed app's
# Accessibility grant to that exact build, so badges and App Menu stop working
# after every rebuild; a real identity keeps one grant across rebuilds.
set -eu
cd "$(dirname "$0")/.."
APP_DIR="${FROSTY_APP_DIR:-/Applications}"

xcodegen generate --quiet
xcodebuild -project Frosty.xcodeproj -scheme Frosty -configuration Release -derivedDataPath build build -quiet

# A normal quit, so Frosty restores the real Dock before it is replaced.
osascript -e 'quit app "Frosty"' 2>/dev/null || true
while pgrep -x Frosty >/dev/null; do sleep 0.2; done

mkdir -p "$APP_DIR"
rm -rf "$APP_DIR/Frosty.app"
cp -R build/Build/Products/Release/Frosty.app "$APP_DIR/"
if [ -n "${FROSTY_SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --sign "$FROSTY_SIGN_IDENTITY" "$APP_DIR/Frosty.app"
fi
open "$APP_DIR/Frosty.app"
