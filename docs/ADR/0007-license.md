# ADR 0007: MIT license

- Status: Accepted
- Date: 2026-11-04

## Context

NIMQO is open source in a public GitHub repository. Upstream
`whatsapp-rust` is MIT licensed.

## Decision

License NIMQO under MIT. Contributions are accepted under the same license
with a Developer Certificate of Origin sign-off.

## Consequences

Every bundled dependency must be MIT-compatible and listed in
`THIRD-PARTY-NOTICES` before it ships. MIT grants no trademark rights; the
NIMQO name and the WhatsApp disclaimer still apply.
