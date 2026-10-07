#!/bin/sh
# Builds build/Agent Island.app with swiftc (no Xcode project). `./build.sh run` also (re)launches it.
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
cp agents.yaml island-guide.md "$APP/Contents/Resources/"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" -o "$APP/Contents/MacOS/AgentIsland" *.swift
SIGN_ID=${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $2; exit }')}
codesign --force --sign "${SIGN_ID:--}" "$APP" 2>/dev/null || codesign --force --sign - "$APP"
echo "built $APP"
if [ "$1" = run ]; then pkill -x AgentIsland && sleep 0.5; open "$APP"; fi
