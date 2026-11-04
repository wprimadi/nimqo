# Upstream compatibility

Results of running `whatsapp-rust` on macOS, which upstream lists as
unqualified (plan 9.1). Only behavior verified here counts as supported.

## Environment

| Item | Value |
| --- | --- |
| Upstream | `oxidezap/whatsapp-rust` `main` @ `0a6ae107810e6f4e2d73bbda0bebe12208472a58` |
| Features | defaults off; `sqlite-storage`, `tokio-transport`, `tokio-runtime`, `tokio-native`, `ureq-client` |
| Storage | upstream SQLite store on SQLCipher (`libsqlite3-sys` 0.38 `bundled-sqlcipher`, CommonCrypto) |
| Rust | 1.99.1 |
| macOS | 27.0.1, Apple Silicon; binary minimum macOS 14.0 |
| Tool | `rust/crates/nimqo-whatsapp`, binary `nimqo-poc` |

## Results

| Check | Result | Date |
| --- | --- | --- |
| Encryption tests without an account (ciphertext on disk incl. WAL, wrong key fails closed, SQLCipher linked, no external `libcrypto`) | Pass | 2026-11-04 |
| QR pairing with a real account | Pass | 2026-11-04 |
| Send text to the test peer | Pass | 2026-11-04 |
| Receive text from the test peer | Pass | 2026-11-04 |
| Protocol and app databases encrypted on disk after a real session | Pass | 2026-11-04 |
| Session restored after restart without re-pairing | Pass | 2026-11-04 |
| Message redelivered once after a refused commit (`NIMQO_FAIL_COMMIT`) | Pass | 2026-11-04 |
| Message redelivered after a hard kill between decrypt and commit | Pending | |
| Reconnect after Wi-Fi off for about 30 s | Pass | 2026-11-04 |
| Incoming image event delivered (content not yet handled; shown as `<non-text>`) | Pass | 2026-11-04 |
| Media transfer | Pending | |

## Known issues

- Terminal-rendered QR codes were not scannable; the QR is shown as SVG in
  a local browser page instead.
- The unsigned development binary may trigger a Keychain access prompt after
  each rebuild. Signed builds will not.
