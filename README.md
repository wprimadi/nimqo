# NIMQO

**Messaging, thoughtfully native.**

NIMQO is a native macOS messaging client for WhatsApp accounts, built with
SwiftUI and a Rust core on top of
[`whatsapp-rust`](https://github.com/oxidezap/whatsapp-rust).

> [!WARNING]
> NIMQO is an **unofficial** third-party application. It is not affiliated
> with, endorsed by, or sponsored by WhatsApp or Meta. It uses an independently
> maintained implementation of the WhatsApp Web protocol, so compatibility can
> break when the service changes, and using it may violate Meta's terms and
> lead to account restrictions. Use a test account until you accept that risk.

## Status

Planning. No usable build exists yet. See [`plan.md`](plan.md) for the
product, architecture, and delivery plan, and [`docs/ADR`](docs/ADR) for
decisions already made.

## Principles

- Native macOS, requiring macOS 14 Sonoma or later.
- All local data encrypted at rest from the first run.
- No telemetry.
- Every merge passes a SonarQube quality gate.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md). Report security issues privately as
described in [SECURITY.md](SECURITY.md), never in public issues.

## License

[MIT](LICENSE)
