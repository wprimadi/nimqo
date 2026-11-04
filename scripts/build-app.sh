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
echo "app ready: $root/app/build/Build/Products/Debug/NIMQO.app"
