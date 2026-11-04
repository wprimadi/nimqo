# Contributing to NIMQO

Thank you for helping. Read [`plan.md`](plan.md) before proposing larger
changes; architectural changes need an ADR in [`docs/ADR`](docs/ADR).

## Ground rules

- Every pull request must pass CI, including the SonarQube quality gate. Do
  not suppress an issue without a written justification in the pull request.
- Never commit secrets, session files, databases, test account data, or real
  conversations. Fixtures must be synthetic.
- Never persist message, session, or media data without encryption.
- Report security issues through [SECURITY.md](SECURITY.md), not here.
- Tests that need a real WhatsApp account never run in CI. The default test
  suite must run without any account or secret.

## Commits

- Use [Conventional Commits](https://www.conventionalcommits.org/), for
  example `feat(pairing): show QR expiry`.
- Sign off every commit to certify the
  [Developer Certificate of Origin](https://developercertificate.org/):
  `git commit -s`.

## Local checks

Scan for secrets before every push. CI runs the same check:

```sh
brew install gitleaks
gitleaks git --redact
```

Build and test commands will be documented here once the Rust workspace and
Xcode project exist.

## Code of conduct

Participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).
