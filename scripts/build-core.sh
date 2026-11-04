#!/bin/sh
# Builds the Rust core as an XCFramework plus its Swift bindings, both under
# app/Generated (not committed). Run before `swift build` in app/.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
profile=${1:-debug}
out="$root/app/Generated"
flag=""
[ "$profile" = release ] && flag="--release"

cd "$root/rust"
cargo build --locked $flag -p nimqo-ffi
lib="$root/rust/target/$profile/libnimqo_ffi"

rm -rf "$out"
mkdir -p "$out/Swift" "$out/include"
cargo run --locked -q --bin uniffi-bindgen -- generate --library "$lib.dylib" \
    --language swift --out-dir "$out/gen"
mv "$out/gen/"*.swift "$out/Swift/"
mv "$out/gen/"*.h "$out/include/"
mv "$out/gen/"*.modulemap "$out/include/module.modulemap"
rm -rf "$out/gen"

# ponytail: host architecture only; lipo arm64 + x86_64 for distribution builds.
xcodebuild -create-xcframework -library "$lib.a" -headers "$out/include" \
    -output "$out/NimqoFFI.xcframework" >/dev/null
echo "core ready: $out"
