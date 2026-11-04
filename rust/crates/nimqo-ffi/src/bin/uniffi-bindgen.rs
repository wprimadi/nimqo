//! Generates the Swift bindings: `scripts/build-core.sh` runs it.

fn main() {
    uniffi::uniffi_bindgen_main();
}
