# ADR 0002: UniFFI boundary

- Status: Accepted. Phase 0 proved the shape; Phase 1 widens the API.
- Date: 2026-11-05

## Context

The Swift app needs the Rust core (ADR 0001) in the same process
(ADR 0003). Plan section 8.7 asks for a small surface with DTOs, typed
errors, defined shutdown, and no blocking of the main actor. Phase 0 built
a minimal bridge and ran it against a real account.

## Decision

- **Tooling.** UniFFI 0.32 with proc macros (no UDL), pinned in
  `Cargo.lock`. The crate `nimqo-ffi` is the only one exported, and it
  depends on NIMQO crates rather than exposing upstream types.
- **Packaging.** `scripts/build-core.sh` builds a static library and
  generates the Swift bindings. It packs the library into
  `app/Generated/NimqoFFI.xcframework`, a directory that is not committed and
  is reproduced on every build.
- **Lifecycle.** One `Core` object owns a Tokio runtime and the client:
  - `Core.start` opens the stores and connects. It blocks, so Swift calls it
    from a detached task, never the main actor.
  - `stop` shuts the client down and is idempotent; `Drop` calls it.
- **Events.** Events reach Swift through a callback interface
  (`CoreListener`) on Rust worker threads. The Swift listener holds the
  model weakly and moves each event to the main actor.
- **Types.** Only DTOs cross the boundary: enums, strings, and integers.
  Upstream structures never do.
- **Errors.** Phase 0 uses one flat error that carries a message. Phase 1
  replaces it with a typed error enum that the UI can branch on.
- **Swift version.** The generated Swift compiles in Swift 5 language mode,
  because it does not pass Swift 6 strict concurrency checks. App code stays
  in Swift 6 mode.

## Alternatives considered

- **Hand-written C ABI:** more unsafe code to maintain, with no gain.
- **swift-bridge:** smaller community, and its async support is less proven.
- **A daemon with IPC:** rejected in ADR 0003.

## Consequences

- **Async functions.** Exported `async fn`s (UniFFI `async_runtime =
  "tokio"`) are the planned way to call message operations from Phase 1 on.
  Their cancellation behavior must be verified before they replace the
  blocking constructor pattern.
- **Event volume.** Events arrive one callback at a time. High-frequency
  events such as history sync must be batched on the Rust side before they
  cross (plan 8.7).
- **Architectures.** The XCFramework holds the host architecture only. A
  universal build is needed before distribution.
- **Shutdown.** Callbacks are owned by the client, so they stop with it.
  Shutdown while a callback is in flight still needs a test in Phase 2.
