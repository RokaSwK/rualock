#!/usr/bin/env bash
# Packages build/Rualock.app into a notarized, stapled DMG for your team.
#
# Needs a "Developer ID Application" certificate in your keychain and stored notary credentials:
#   xcrun notarytool store-credentials rualock --apple-id you@example.com --team-id TEAMID
#   NOTARY_PROFILE=rualock scripts/notarize.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE=${NOTARY_PROFILE:-rualock}
APP=build/Rualock.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG=build/Rualock-$VERSION.dmg

IDENTITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)/\1/p' | head -1)
if [ -z "$IDENTITY" ]; then
    echo "error: $APP isn't signed with a Developer ID Application certificate." >&2
    echo "Create one at developer.apple.com > Certificates, install it, then run scripts/build.sh again." >&2
    exit 1
fi

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -R "$APP" "$stage/"
ln -s /Applications "$stage/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname Rualock -srcfolder "$stage" -format UDZO "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
echo "ready: $DMG"
