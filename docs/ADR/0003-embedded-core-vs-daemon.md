# ADR 0003: Embedded Rust core, no daemon

- Status: Accepted
- Date: 2026-11-04

## Context

The reference client `oxidezap/client` runs the session in a daemon serving
several front ends over a local socket. NIMQO has one front end.

## Decision

Embed the Rust core in the app process. No daemon, socket, or custom IPC.
Keep `panic = "unwind"` in the release profile so UniFFI turns Rust panics
into errors instead of aborting the UI.

## Alternatives considered

- Daemon with IPC: needed only for multiple front ends, independent service
  lifetime, or process isolation. None applies yet, and a local socket adds
  an attack surface.

## Consequences

A fatal Rust fault takes down the UI. Closing the main window must not end
the session; quitting the app does. Revisit if a concrete requirement for
process separation appears.
