#!/usr/bin/env bash
# Builds build/Rualock.app: Apple silicon binary, Core ML model, icon, signed with the hardened runtime.
#
#   scripts/build.sh                      # signs with Developer ID if you have one, else Apple Development
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build.sh
#   VERSION=1.2.0 BUNDLE_ID=com.example.rualock scripts/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${VERSION:-1.0.0}
BUILD=${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
BUNDLE_ID=${BUNDLE_ID:-com.rualock.mac}
OUT=build
APP=$OUT/Rualock.app

# 1. Face model (downloaded from the OpenCV zoo, checksum-pinned, converted once and cached).
if [ ! -d "$OUT/SFace.mlpackage" ]; then
    uv run scripts/convert_model.py "$OUT/SFace.mlpackage" "$OUT"
fi

# 2. Icon.
if [ ! -f "$OUT/AppIcon.icns" ]; then
    swift scripts/make_icon.swift "$OUT/AppIcon.iconset"
    iconutil -c icns "$OUT/AppIcon.iconset" -o "$OUT/AppIcon.icns"
fi

# 3. Binary (Apple silicon; macOS 27 no longer runs on Intel).
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Rualock"

# 4. Bundle.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Rualock"
cp "$OUT/AppIcon.icns" "$APP/Contents/Resources/"
xcrun coremlcompiler compile "$OUT/SFace.mlpackage" "$APP/Contents/Resources" >/dev/null
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" -e "s/__BUNDLE_ID__/$BUNDLE_ID/" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"

# 5. Sign.
if [ -z "${SIGN_IDENTITY:-}" ]; then
    ids=$(security find-identity -v -p codesigning)
    SIGN_IDENTITY=$(grep -o '"Developer ID Application: [^"]*"' <<<"$ids" | head -1 | tr -d '"' || true)
    [ -n "$SIGN_IDENTITY" ] || SIGN_IDENTITY=$(grep -o '"Apple Development: [^"]*"' <<<"$ids" | head -1 | tr -d '"' || true)
    [ -n "$SIGN_IDENTITY" ] || SIGN_IDENTITY=-
fi
flags=(--force --options runtime --entitlements Resources/Rualock.entitlements --sign "$SIGN_IDENTITY")
[[ "$SIGN_IDENTITY" == "Developer ID Application:"* ]] && flags+=(--timestamp)
codesign "${flags[@]}" "$APP"
codesign --verify --strict "$APP"

echo "built $APP $VERSION ($BUILD), signed by: ${SIGN_IDENTITY%% (*}"
