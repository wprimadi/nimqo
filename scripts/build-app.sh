#!/bin/sh
# One command to build the app: Rust core, Xcode project, app bundle.
# `scripts/build-app.sh test` also runs the Swift tests.
# CONFIG=Release builds the core and the app optimised (default Debug).
# ARCHS: "arm64" (default), "x86_64", or "arm64 x86_64" for a universal app.
set -eu
ARCHS=${ARCHS:-arm64}
export ARCHS
root=$(cd "$(dirname "$0")/.." && pwd)
config=${CONFIG:-Debug}
profile=debug
[ "$config" = Release ] && profile=release
"$root/scripts/build-core.sh" "$profile"
cd "$root/app"
xcodegen generate --quiet
action=${1:-build}
# The same archs as the core (see build-core.sh); a Release build would
# otherwise be universal whatever the core holds.
xcodebuild -project NIMQO.xcodeproj -scheme NIMQO -configuration "$config" \
    -derivedDataPath build -quiet ARCHS="$ARCHS" ONLY_ACTIVE_ARCH=NO "$action"
app="$root/app/build/Build/Products/$config/NIMQO.app"
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
