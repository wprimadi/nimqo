# Upstream compatibility

Results of running `whatsapp-rust` on macOS, which upstream lists as
unqualified (plan 9.1). Only behavior verified here counts as supported.

## Environment

| Item | Value |
| --- | --- |
| Upstream | `oxidezap/whatsapp-rust` `main` @ `0a6ae107810e6f4e2d73bbda0bebe12208472a58`, built from the fork `wprimadi/whatsapp-rust` branch `nimqo/video-fec-receive` (see Patches) |
| Features | defaults off; `sqlite-storage`, `tokio-transport`, `tokio-runtime`, `tokio-native`, `ureq-client` |
| Storage | upstream SQLite store on SQLCipher (`libsqlite3-sys` 0.38 `bundled-sqlcipher`, CommonCrypto) |
| Rust | 1.99.1 |
| macOS | 27.0.1, Apple Silicon; binary minimum macOS 14.0 |
| Tools | `rust/crates/nimqo-whatsapp` binary `nimqo-poc`; SwiftPM app in `app/` via `nimqo-ffi` |

## Patches

NIMQO builds from a fork until these land upstream. Each is a commit on
`wprimadi/whatsapp-rust` branch `nimqo/video-fec-receive`, based on the
upstream commit above.

- `0fb3c7f` voip: rebuild lost inbound video packets from the peer's FEC. Upstream decrypted the peer's video repair packets and dropped them, so every lost packet froze the picture until a keyframe, and the engine asked for a keyframe on each loss.
- `d5b1fe5`, `61704b0` voip: deliver a 1:1 peer's screen-share state, from the peer only. Upstream accepted the `screen_share` stanza only from group participants, so a phone sharing its screen in a 1:1 call looked like a camera and was cropped.
- `f936769` voip: keep a paced-out picture's fragments in one access unit. A shared screen's large pictures go out over more than 8 ms of media time offset, which upstream read as a new picture mid-NAL: the rest became orphan fragments and the screen froze.
- `20b7920` voip: review follow-up to the inbound video hold (upstream #1872): held gaps expire on the engine timer, late originals are dropped instead of cutting off a rebuilt NAL, restart-sized jumps request a keyframe, holds no longer add up across gaps, short repairs are retried, and audio on a rebuilt carrier is played.
- `c572dd7` voip: a group video offer spells its codecs `enc="h.264" dec="H264"` with no `orientation`, as the 1:1 offer already does. The old spelling was acked and never rang.

## Notes

- Event callbacks get a 256-event mailbox by default and the newest event is dropped when it is full. The address book arrives as one burst of contact events (about 1,500 on the test account), so NIMQO raises the buffer to 50,000 (`EVENT_DELIVERY`).
- `lid_contact` app-state entries are known upstream but not reported as events; none were seen on the test account.

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
| Message redelivered after `kill -9` between decrypt and commit (`NIMQO_COMMIT_DELAY`), stored exactly once | Pass | 2026-11-05 |
| Reconnect after Wi-Fi off for about 30 s | Pass | 2026-11-04 |
| Incoming image event delivered (content not yet handled; shown as `<non-text>`) | Pass | 2026-11-04 |
| Receive an image from the test peer, stored encrypted (ADR 0006), opened with `/show` | Pass | 2026-11-05 |
| Send an image to the test peer with `/img` | Pass | 2026-11-05 |
| SwiftUI app through UniFFI: session restored, status shown, reconnect after Wi-Fi off | Pass | 2026-11-05 |
| Xcode-built app (Phase 1 shell): connects, main window with sidebar | Pass | 2026-11-05 |
| App: Offline on Wi-Fi off, reconnect on return (`NWPathMonitor`) | Pass | 2026-11-05 |
| App: reconnect after system sleep and wake | Pass | 2026-11-05 |
| Second process refused while the app holds the data directory lock | Pass | 2026-11-05 |
| First-run disclosure shown once, before any connection | Pass | 2026-11-05 |
| Unlinked from the phone: app shows Logged out; reset destroys key and data | Pass | 2026-11-05 |
| Pairing by phone number code after reset | Pass | 2026-11-05 |
| Read-only chat list and timeline for all chats (live delivery) | Pass | 2026-11-05 |
| History sync after pairing: chats, groups with subjects, no UI stalls | Pass | 2026-11-05 |

## Limitations register

Last verified at the upstream commit above. "Verified" means a real-account
run on macOS; everything else is untested here, whatever upstream documents.

| Feature | Upstream API | NIMQO adapter | Result | Known limitation |
| --- | --- | --- | --- | --- |
| QR pairing | `Bot::on_qr_code` | `nimqo-poc`, `nimqo-ffi` | Verified | Pairing code login not tried |
| Session store | `SqliteDatabase` + `with_connection_init` | `stores::open` (SQLCipher) | Verified | Store uses device id 1; one linked device per data dir |
| Inbound durability | `InboundDurabilityHook` | `inbox::Inbox` | Verified (refused commit, `kill -9`) | Peer-only storage in Phase 0; other chats are acknowledged unstored. Upstream warns when processing exceeds `MAX_MESSAGE_DELAY` (20 s): commits must stay well below it |
| Text send/receive | `Client::send_message`, `on_message` | `nimqo-poc` | Verified | One-to-one only; groups untested |
| Images | `Client::download`, `Client::upload`, `media::image_message` | `nimqo-poc`, `media` (ADR 0006) | Verified | Whole file in memory, 16 MiB cap; video, audio, documents untested |
| Reconnect | built in, `Client::reconnect_immediately` | `nimqo-ffi` state machine, app network/wake observers | Verified (Wi-Fi off, sleep/wake) | Long outages untested |
| Swift bridge | n/a | `nimqo-ffi` (UniFFI 0.32) | Verified | Status and QR only; see ADR 0002 |
| Proxy, VPN, custom root CA | `ureq-client`, `tokio-transport` | none | Untested | Plan 9.3 requires a recorded result |
| History sync, receipts, presence | various | none | Untested | Phase 3 |

Upstream is pinned to a `main` commit (crate version 0.7.0), not a release,
and is pre-1.0 with breaking changes between releases. Every upstream bump
re-runs this table.

## Known issues

- Terminal-rendered QR codes were not scannable; the QR is shown as SVG in
  a local browser page instead.
- The unsigned development binary may trigger a Keychain access prompt after
  each rebuild. Signed builds will not.
- `swift run` starts the app without a bundle, so macOS treats it as a
  background tool. The app sets a regular activation policy itself.
- Running `nimqo-poc` and the app at the same time makes two connections
  for one linked device. Run one at a time.
