#!/usr/bin/env bash
# Builds Down with SwiftPM (Command Line Tools only, no Xcode) and assembles build/Down.app.
#   scripts/bundle.sh [release|debug]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIG" --product Down
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="$ROOT/build/Down.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Down" "$APP/Contents/MacOS/Down"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/Down.icns ]]; then cp Resources/Down.icns "$APP/Contents/Resources/Down.icns"; fi
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Prefer a stable local identity (scripts/make-dev-cert.sh) so macOS privacy grants survive rebuilds.
IDENTITY="${DOWN_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -q "Down Local Signing"; then
  IDENTITY="Down Local Signing"
fi
codesign --force --options runtime --timestamp=none \
  --entitlements Resources/Down.entitlements \
  --sign "${IDENTITY:--}" "$APP"

echo "Built $APP ($CONFIG, signed with ${IDENTITY:-ad-hoc identity})"
