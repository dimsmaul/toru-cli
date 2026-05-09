#!/usr/bin/env bash
# Build the Toru CLI macOS app and package it as a distributable .dmg.
# No code-signing identity required — falls back to ad-hoc (`codesign -`).
# First-time users on macOS will need to right-click → Open to bypass
# Gatekeeper, since the build isn't notarized.
#
# Usage:
#   scripts/build-dmg.sh                 # version derived from git
#   scripts/build-dmg.sh v1.2.3          # explicit version
#
# Env overrides:
#   PROJECT  — defaults to "Toru CLI.xcodeproj"
#   SCHEME   — defaults to "Toru CLI"
#   CONFIG   — defaults to "Release"
#   OUT_DIR  — defaults to ./dist
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="${PROJECT:-Toru CLI.xcodeproj}"
SCHEME="${SCHEME:-Toru CLI}"
CONFIG="${CONFIG:-Release}"
OUT_DIR="${OUT_DIR:-dist}"
VERSION="${1:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"

DERIVED="$OUT_DIR/.derived"
rm -rf "$OUT_DIR"
mkdir -p "$DERIVED"

echo "==> xcodebuild ($CONFIG)"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    ONLY_ACTIVE_ARCH=NO \
    build \
    | xcbeautify --quiet 2>/dev/null || \
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    ONLY_ACTIVE_ARCH=NO \
    build

APP_PATH=$(find "$DERIVED/Build/Products/$CONFIG" -maxdepth 2 -name "*.app" -type d | head -1)
[[ -n "$APP_PATH" ]] || { echo "no .app produced" >&2; exit 1; }

APP_NAME=$(basename "$APP_PATH" .app)
SAFE_NAME="${APP_NAME// /-}"
DMG_PATH="$OUT_DIR/${SAFE_NAME}-${VERSION}.dmg"

echo "==> Ad-hoc sign"
codesign --force --deep --sign - "$APP_PATH"

echo "==> Stage DMG contents"
STAGE=$(mktemp -d)
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> hdiutil create"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG_PATH"

rm -rf "$STAGE"
echo "==> Done: $DMG_PATH"
