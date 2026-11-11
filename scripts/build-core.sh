#!/bin/sh
# Builds the Rust core as an XCFramework plus its Swift bindings, both under
# app/Generated (not committed). Run before `swift build` in app/.
# `build-core.sh [debug|release]`; ARCHS picks the Macs it runs on: "arm64"
# (default), "x86_64", or "arm64 x86_64" for a universal core.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
profile=${1:-debug}
archs=${ARCHS:-arm64}
out="$root/app/Generated"
flag=""
[ "$profile" = release ] && flag="--release"

cd "$root/rust"
libs=""
for arch in $archs; do
    case "$arch" in
        arm64) target=aarch64-apple-darwin ;;
        x86_64) target=x86_64-apple-darwin ;;
        *) echo "unknown arch: $arch" >&2; exit 1 ;;
    esac
    cargo build --locked $flag -p nimqo-ffi --target "$target"
    libs="$libs $root/rust/target/$target/$profile/libnimqo_ffi.a"
    # Bindings read from any one build: they are the same for every arch.
    dylib="$root/rust/target/$target/$profile/libnimqo_ffi.dylib"
done

# One static library holding every arch asked for.
lib="$root/rust/target/nimqo-$profile.a"
# shellcheck disable=SC2086 # one path per arch, none with spaces
lipo -create $libs -output "$lib"

rm -rf "$out"
mkdir -p "$out/Swift" "$out/include"
cargo run --locked -q --bin uniffi-bindgen -- generate --library "$dylib" \
    --language swift --out-dir "$out/gen"
mv "$out/gen/"*.swift "$out/Swift/"
mv "$out/gen/"*.h "$out/include/"
mv "$out/gen/"*.modulemap "$out/include/module.modulemap"
rm -rf "$out/gen"

xcodebuild -create-xcframework -library "$lib" -headers "$out/include" \
    -output "$out/NimqoFFI.xcframework" >/dev/null
echo "core ready ($archs): $out"
