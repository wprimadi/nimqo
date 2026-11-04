# ADR 0006: Media encryption format

- Status: Accepted
- Date: 2026-11-05

## Context

ADR 0004 requires media to be encrypted at rest with a reviewed streaming
AEAD. Media can be large, so the format has to allow segment-by-segment
processing, and it has to detect truncation, reordering, and tampering.

## Decision

A file is `"NQM1" || salt[32] || segments`.

- File key: HKDF-SHA256 with the media root key (derived from the master key
  with label `nimqo/v1/media`), the random 32-byte salt, and info
  `nimqo/v1/media-file`. Every file therefore has its own key.
- Segments: 64 KiB of plaintext each, sealed with ChaCha20-Poly1305 in the
  STREAM construction (Hoang, Reyhanitabar, Rogaway, Vizár 2015), using
  RustCrypto `aead-stream` `StreamBE32`. The final segment carries the "last"
  flag, which is how truncation is detected. An empty file is one empty final
  segment.
- The 36-byte header is the associated data of every segment, so changing
  the magic or the salt fails authentication.
- Because the file key is unique, the STREAM nonce prefix is zero.

This is the same construction age and Tink use; NIMQO adds no cryptography
of its own beyond choosing parameters.

## Alternatives considered

- age: a complete format, but built for recipients and passphrases. A
  symmetric key from the Keychain would need its scrypt mode or a dummy
  recipient.
- One AES-GCM seal per file: has to hold the whole file in memory and has a
  smaller nonce margin.
- Keeping WhatsApp's own media encryption: its keys travel inside messages,
  which are stored in the app database, so it adds nothing locally.

## Consequences

- The `NQM1` magic versions the format. A change of algorithm or segment size
  means `NQM2` and a migration.
- Phase 0 encrypts and decrypts whole buffers in memory, capped at 16 MiB.
  Segment-by-segment file I/O for video comes in Phase 3.
- Tests in `rust/crates/nimqo-whatsapp/src/media.rs` cover:
  - round trips at segment boundaries;
  - tampering, header changes, truncation, and a wrong key;
  - a fresh key for every file.
