# ADR 0005: Minimum macOS 14 Sonoma

- Status: Accepted
- Date: 2026-11-04

## Context

OS X 10.11 was requested and evaluated. Xcode 27 deploys to macOS 12.0 at
minimum, Rust to 10.12 on Intel and 11.0 on Apple Silicon, and SwiftUI needs
10.15. El Capitan cannot run on Apple Silicon and has no security updates.

## Decision

Require macOS 14 or later. Use Liquid Glass behind `#available(macOS 26, *)`
and system materials on macOS 14 and 15, through one design-system wrapper.
Build Rust with `MACOSX_DEPLOYMENT_TARGET=14.0`.

## Alternatives considered

- macOS 12: requires `NSStatusItem` and no `@Observable`; more AppKit code.
- macOS 26: no fallback, but the smallest audience.

## Consequences

Two visual paths to test. macOS 14 support stays unverified until a macOS 14
machine or VM is available, and must not be claimed before then.
