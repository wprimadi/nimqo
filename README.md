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

Phase 0 proof of concept. Pairing, encrypted storage, text, and images
work against a real account; there is no usable app yet. See
[`plan.md`](plan.md) for the plan, [`docs/ADR`](docs/ADR) for decisions, and
[`docs/UPSTREAM-COMPATIBILITY.md`](docs/UPSTREAM-COMPATIBILITY.md) for what
has been verified.

To try the Phase 0 app (macOS 14+, Rust, Xcode):

```sh
./scripts/build-core.sh
cd app && NIMQO_TEST_PEER=+<number> swift run
```

Only the test number may be stored or messaged. Do not run the app and
`nimqo-poc` at the same time: they share one linked device.

## Principles

- Native macOS, requiring macOS 14 Sonoma or later.
- All local data encrypted at rest from the first run.
- No telemetry.
- Every push passes a local quality gate (`.githooks/pre-push`).

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md). Report security issues privately as
described in [SECURITY.md](SECURITY.md), never in public issues.

## License

[MIT](LICENSE)
