#!/bin/sh
# One command to build the app: Rust core, Xcode project, app bundle.
# `scripts/build-app.sh test` also runs the Swift tests.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
"$root/scripts/build-core.sh"
cd "$root/app"
xcodegen generate --quiet
action=${1:-build}
xcodebuild -project NIMQO.xcodeproj -scheme NIMQO -configuration Debug \
    -derivedDataPath build -quiet "$action"
app="$root/app/build/Build/Products/Debug/NIMQO.app"
# The maintainer's self-signed certificate (Secret/, never committed; see
# README "Code signing") keeps one app identity across updates, so the
# Keychain and microphone/camera permissions are not asked again. Without
# it the build stays ad hoc signed.
keychain="$root/Secret/nimqo-signing.keychain-db"
if [ -f "$keychain" ]; then
    security unlock-keychain -p "$(cat "$root/Secret/keychain-password.txt")" "$keychain"
    identity=$(security find-identity -p codesigning "$keychain" | awk '/NIMQO Code Signing/ { print $2; exit }')
    codesign --force --deep --preserve-metadata=entitlements --sign "$identity" \
        --keychain "$keychain" "$app"
    echo "signed with NIMQO Code Signing"
fi
echo "app ready: $app"
