# ADR 0004: Mandatory encryption at rest

- Status: Accepted (design); implementation to be proven in Phase 0
- Date: 2026-11-04

## Context

NIMQO stores protocol keys, message history, and media locally. Upstream
`whatsapp-rust` stores protocol state in plain SQLite by default, and the
repository is public, so security must rest on keys, not obscurity.

## Decision

- Encrypt every NIMQO-persisted byte from the first run. No plaintext mode,
  no migration from plaintext, no silent fallback; fail closed when the key
  is unavailable.
- A 256-bit master key from the system CSPRNG, stored in the macOS Keychain
  as device-only and non-synchronizable. HKDF derives separate keys for the
  protocol database, app database, and media.
- Both databases use SQLCipher (`libsqlite3-sys` `bundled-sqlcipher`, built
  with CommonCrypto). Upstream's store is keyed through
  `SqliteDatabaseConfig::with_connection_init`, which runs before migrations.
- Media is encrypted per file with a reviewed streaming AEAD (ADR 0006).
- Logout destroys keys first, then files.

## Alternatives considered

- FileVault only: does not protect against other processes of the same user
  or copied files. Rejected as the sole control.
- Passphrase or cloud key escrow: adds recovery risk; deferred.

## Consequences

Losing the Keychain item loses local history and requires re-pairing; this
is disclosed in onboarding. The build must verify no external `libcrypto` is
linked. Plan section 11.3 lists the required tests and residual risks.
