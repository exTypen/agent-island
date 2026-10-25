#!/bin/sh
# Builds, signs, notarizes and staples build/AgentIsland-<version>.dmg for distribution (version from Info.plist).
#   ./release.sh
# Needs a "Developer ID Application" certificate in the login keychain and notary credentials stored as a profile:
#   xcrun notarytool store-credentials loupe-notary --apple-id <apple-id> --team-id <team-id>
set -e
cd "$(dirname "$0")"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
PROFILE="${NOTARY_PROFILE:-loupe-notary}"
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' 'index($2, "Developer ID Application") == 1 { print $2; exit }')}"
[ -n "$SIGN_ID" ] || { echo "No Developer ID Application certificate found." >&2; exit 1; }
SIGN_ID="$SIGN_ID" ./build.sh

DMG="build/AgentIsland-$VERSION.dmg"
STAGE=$(mktemp -d)
cp -R "build/Agent Island.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Agent Island $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp -s "$SIGN_ID" "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
shasum -a 256 "$DMG"
