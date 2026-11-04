# ADR 0001: Native SwiftUI app with a Rust core

- Status: Accepted
- Date: 2026-11-04

## Context

NIMQO must feel native on macOS and needs a WhatsApp Web protocol
implementation. `whatsapp-rust` provides the protocol in Rust.

## Decision

Build the interface with SwiftUI and AppKit. Put protocol, domain, storage,
and sync logic in a Rust core. Only the `nimqo-whatsapp` crate depends on
`whatsapp-rust`; the rest of NIMQO sees NIMQO domain types.

## Alternatives considered

- Web wrapper (Electron, Tauri): not native, heavier.
- Reuse `oxidezap/client` (GPUI): not native macOS UI.
- Reimplement the protocol in Swift: unjustified cost and risk.

## Consequences

Two languages and a Swift/Rust boundary to maintain (see ADR 0002). Upstream
API churn is contained in one adapter crate.
