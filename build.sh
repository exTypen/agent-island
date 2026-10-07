#!/bin/sh
# Builds Agent Island with swiftc (no Xcode project).
#
#   ./build.sh           build build/Agent Island.app
#   ./build.sh run       build and (re)launch it from build/
#   ./build.sh install   build, move it to /Applications (one copy, so Spotlight shows one) and launch it
#
# Signing: the first "Apple Development" identity in your keychain, so macOS keeps Microphone, Speech Recognition and
# Accessibility grants across rebuilds. Without one it signs ad hoc, which works but re-asks for those after each build.
# Override with SIGN_ID="<identity name or hash>" (SIGN_ID=- forces ad hoc).
set -e
cd "$(dirname "$0")"
APP="build/Agent Island.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
cp agents.yaml island-guide.md AppIcon.icns "$APP/Contents/Resources/"
# Xcode 26's actool compiles the Icon Composer icon into Assets.car, which macOS 26 renders natively (otherwise it
# boxes the app icon in a grey frame) plus a matching AppIcon.icns. Older toolchains keep the plain AppIcon.icns.
# actool runs in a helper process with another working directory: every path must be absolute.
xcrun actool "$PWD/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --app-icon AppIcon --include-all-app-icons \
    --output-partial-info-plist "$PWD/build/icon-info.plist" --enable-on-demand-resources NO --development-region en \
    --target-device mac --minimum-deployment-target 14.0 --platform macosx --errors >/dev/null 2>&1 \
    || echo "note: actool couldn't compile AppIcon.icon (needs Xcode 26); using AppIcon.icns"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" -o "$APP/Contents/MacOS/AgentIsland" *.swift
SIGN_ID=${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $2; exit }')}
codesign --force --sign "${SIGN_ID:--}" "$APP" 2>/dev/null || codesign --force --sign - "$APP"
echo "built $APP"

case "$1" in
run)
    pkill -x AgentIsland && sleep 0.5
    open "$APP" ;;
install)
    pkill -x AgentIsland && sleep 0.5
    rm -rf "/Applications/Agent Island.app"
    mv "$APP" /Applications/
    echo "installed /Applications/Agent Island.app"
    open "/Applications/Agent Island.app" ;;
esac
