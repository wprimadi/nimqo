# Security Policy

## Reporting a vulnerability

Report vulnerabilities privately through
[GitHub private vulnerability reporting](https://github.com/wprimadi/nimqo/security/advisories/new).
Do not open a public issue, pull request, or discussion.

Include the affected version or commit, steps to reproduce, and the impact you
expect. Never include real session files, keys, phone numbers, or message
content.

The maintainer aims to acknowledge a report within 7 days and to agree on a
disclosure date once a fix is available.

## Supported versions

NIMQO has no release yet. Once releases exist, only the latest release
receives security fixes.

## Scope

In scope: NIMQO's code, its local storage and encryption, its build and
release pipeline, and how it uses its dependencies.

Out of scope: vulnerabilities in WhatsApp's service or in upstream
`whatsapp-rust`. Report those to their owners. NIMQO cannot protect against a
fully compromised macOS user account or device.
