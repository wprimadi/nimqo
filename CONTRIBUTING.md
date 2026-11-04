# Contributing to NIMQO

Thank you for helping. Read [`plan.md`](plan.md) before proposing larger
changes; architectural changes need an ADR in [`docs/ADR`](docs/ADR).

## Ground rules

- Every push must pass the local quality gate in `.githooks/pre-push`. There
  is no hosted CI. Do not bypass it with `--no-verify`, and justify any
  `#[allow]` or `swiftlint:disable` in a comment.
- Never commit secrets, session files, databases, test account data, or real
  conversations. Fixtures must be synthetic.
- Never persist message, session, or media data without encryption.
- Report security issues through [SECURITY.md](SECURITY.md), not here.
- Tests that need a real WhatsApp account are never part of the quality
  gate. The default test suite must run without any account or secret.

## Commits

- Use [Conventional Commits](https://www.conventionalcommits.org/), for
  example `feat(pairing): show QR expiry`.
- Sign off every commit to certify the
  [Developer Certificate of Origin](https://developercertificate.org/):
  `git commit -s`.

## Local checks

Enable the quality gate once per clone. It runs on every `git push`:

```sh
brew install gitleaks cargo-audit cargo-deny swiftlint swiftformat
git config core.hooksPath .githooks
```

The gate scans pushed commits for secrets and, once the code exists, runs
rustfmt, Clippy, tests, `cargo audit`, `cargo deny`, SwiftFormat, and
SwiftLint. Build commands will be documented here once the Rust workspace
and Xcode project exist.

## Code of conduct

Participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).
