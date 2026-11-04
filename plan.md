# NIMQO

## Product, Architecture & Development Master Plan

**Document type:** Product Requirements + Technical Architecture +
Delivery Plan\
**Version:** 1.2\
**Status:** Proposed baseline for development\
**Date:** 4 November 2026\
**Platform:** macOS\
**Minimum OS:** macOS 14 Sonoma\
**License:** MIT\
**Repository:** <https://github.com/wprimadi/nimqo> (public)\
**Primary stack:** Swift 6, SwiftUI, AppKit, Rust, `whatsapp-rust`,
UniFFI, SQLCipher\
**Working product name:** NIMQO

### Changes in 1.2

-   No GitHub Actions CI and no SonarQube. Quality is enforced by a local
    gate in a versioned `pre-push` hook and by review (Section 16.6).

### Changes in 1.1

-   Minimum OS set to macOS 14 with a Liquid Glass fallback.
-   Open source distribution with a mandatory quality gate.
-   Encryption at rest is mandatory from the first persisted byte.
-   Corrections from a review of upstream `whatsapp-rust` at v0.7.0 and
    `main`, including its macOS qualification status, message storage,
    acknowledgement behavior, and event model.

------------------------------------------------------------------------

## 1. Executive Summary

NIMQO is a native macOS messaging application built around the WhatsApp
Web protocol through the Rust library
[`whatsapp-rust`](https://github.com/oxidezap/whatsapp-rust). Its
purpose is to provide a fast, lightweight, secure, and visually polished
desktop experience that feels at home on macOS.

NIMQO is not intended to be a web page wrapped in a desktop shell. Its
interface, window behavior, menu bar integration, notifications,
keyboard interactions, accessibility, and visual materials should use
native Apple frameworks.

The application is divided into two principal layers:

-   **SwiftUI + AppKit:** native macOS presentation, application
    lifecycle, windows, Menu Bar Extra, notifications, permissions,
    media pickers, and platform integrations.
-   **Rust core:** WhatsApp protocol integration, session lifecycle,
    message processing, synchronization, domain logic, persistence
    adapters, and background tasks.

UniFFI is the initial interoperability choice between Swift and Rust.
The Rust core should be embedded in the application process for the
first implementation. A separate daemon and IPC layer are not part of
the initial architecture unless real technical requirements justify
them.

### Product principles

1.  **Functionality:** implement and validate the widest practical set
    of WhatsApp capabilities exposed by the selected protocol library.
2.  **Lightweight:** avoid unnecessary processes, polling, duplicated
    state, excessive rendering, and unnecessary dependencies.
3.  **Fast:** keep UI work on the main actor, run protocol and storage
    work asynchronously, and optimize measured bottlenecks.
4.  **Secure and private:** protect local session material and user
    data, minimize data collection, and make security behavior explicit.
5.  **Beautiful:** deliver a coherent, native macOS design with
    restrained Liquid Glass treatment.
6.  **Reliable:** survive network changes, sleep/wake, reconnects,
    application restarts, and library errors without corrupting local
    state.

### Important product limitation

`whatsapp-rust` is an unofficial implementation of the WhatsApp Web
protocol. It is not an official Meta SDK. Protocol changes can break
compatibility, and use may be inconsistent with Meta's terms or policies
and may expose an account to restrictions. NIMQO must communicate this
risk clearly and must never claim affiliation with, endorsement by, or
certification from WhatsApp or Meta.

------------------------------------------------------------------------

## 2. Product Identity and Positioning

### 2.1 Name

**NIMQO**

Use the name as an independent product identity. Do not use WhatsApp's
logo, official app icon, or visual identity in a way that implies the
product is official.

### 2.2 Product description

> NIMQO is a native macOS messaging client focused on speed, privacy,
> and a beautifully considered desktop experience.

### 2.3 Positioning

NIMQO should feel:

-   Native, not web-like.
-   Quiet and focused, not visually noisy.
-   Responsive, not animation-heavy.
-   Private by default, not cloud-dependent.
-   Premium, but not over-designed.

### 2.4 Brand and interface language

-   Product name: `NIMQO`
-   App display name: `NIMQO`
-   Bundle identifier: reserve a reverse-DNS identifier after domain
    ownership is decided, e.g. `com.<publisher>.nimqo`.
-   Suggested tagline: **Messaging, thoughtfully native.**
-   Avoid using WhatsApp trademarks as part of NIMQO's product name,
    domain, bundle identifier, or marketing identity.

The name NIMQO is a selected working brand, not a legal clearance.
Before public distribution, check domain availability, Apple App Store
naming conflicts, GitHub organization/repository conflicts, PDKI, and
relevant WIPO trademark databases. This document does not represent a
trademark search or legal opinion.

------------------------------------------------------------------------

## 3. Goals, Non-Goals, and Success Criteria

### 3.1 Goals

-   Pair an account using QR code and, where supported, pairing code.
-   Maintain a persistent linked-device session.
-   Receive, display, and send supported message types.
-   Keep chat history and application state locally.
-   Support media upload/download and preview.
-   Support groups, contacts, reactions, replies, receipts, and other
    capabilities exposed by the protocol library.
-   Provide native macOS notifications and menu bar access.
-   Run efficiently while the main window is hidden.
-   Provide a secure local data model and predictable logout/reset
    behavior.
-   Make the application testable independently of the SwiftUI
    interface.
-   Publish maintainable open source code that passes the
    local quality gate (Section 16.6).

### 3.2 Non-goals for the initial release

-   Reimplementing the WhatsApp protocol from scratch.
-   Building a WhatsApp server or cloud synchronization service.
-   Providing a browser version or Windows/Linux application.
-   Guaranteeing compatibility with every official WhatsApp feature.
-   Bypassing WhatsApp account controls, rate limits, or security
    mechanisms.
-   Building an AI assistant, MCP server, plugin marketplace, or
    automation engine before core messaging is stable.
-   Supporting multiple WhatsApp accounts in the first milestone unless
    the library's account/session isolation is proven and this
    requirement is explicitly approved.
-   Promising end-to-end encrypted local backups unless a complete
    key-management and recovery design is implemented.

### 3.3 Success criteria

A release candidate is successful when:

-   A new user can pair, restart NIMQO, and reconnect without repeating
    pairing under normal conditions.
-   Core messaging flows work against real test accounts.
-   Incoming messages appear without manual refresh.
-   Sending and receiving do not freeze the interface.
-   The app behaves correctly when the network disconnects and returns.
-   Closing the main window does not unintentionally terminate the
    connection.
-   The menu bar item provides reliable status and quick access.
-   Local data and session material follow the documented protection
    model.
-   Critical accessibility, keyboard, and VoiceOver flows are usable.
-   No known critical or high-severity security defect remains open.
-   The local quality gate passes on the release commit.
-   No message, session, or media content is stored unencrypted by
    NIMQO, except the documented temporary and OS-owned cases.
-   Performance goals are measured on supported hardware rather than
    assumed.

------------------------------------------------------------------------

## 4. Target Platform and Compatibility

### 4.1 Initial platform

-   macOS only.
-   Apple Silicon is the primary target.
-   Build and test on Apple Silicon.
-   Consider Intel support only if there is a clear distribution
    requirement and all native dependencies support it.

### 4.2 Minimum macOS version

**Decision: macOS 14 Sonoma or later.**

-   OS X 10.11 was evaluated and rejected. On the current toolchain,
    Xcode 27 has a minimum deployment target of macOS 12.0, Rust's minimum
    is 10.12 on Intel and 11.0 on Apple Silicon, and SwiftUI requires
    10.15. El Capitan also cannot run on Apple Silicon and no longer
    receives security updates.
-   macOS 14 provides `MenuBarExtra`, `NavigationSplitView`,
    `SMAppService`, and `@Observable`.
-   Liquid Glass APIs are gated with `#available(macOS 26, *)`. Earlier
    versions use system materials through one design-system wrapper. Do
    not fake Liquid Glass with custom blur layers.
-   Test on macOS 14, macOS 26, and the current release. A build made on
    a newer OS is not evidence of support for macOS 14.
-   **Open item:** a macOS 14 test machine or VM is not yet available.
    Until one exists, macOS 14 support is unverified and must not be
    claimed in release notes. Required before beta.
-   Pass `MACOSX_DEPLOYMENT_TARGET=14.0` to Cargo so bundled C code, such
    as SQLCipher and `ring`, matches the app target.

### 4.3 Architecture targets

-   `arm64` for Apple Silicon.
-   Add `x86_64` only if Intel support is approved.
-   Produce a universal binary only when there is a real need; do not
    add build complexity by default.

### 4.4 macOS platform integrations

Use native frameworks for:

-   SwiftUI: application UI and scene composition.
-   AppKit: lifecycle and behaviors not fully exposed by SwiftUI.
-   UserNotifications: local notifications.
-   Keychain Services: secret and key material protection.
-   AVFoundation: microphone, camera, and media capture/playback where
    needed.
-   VideoToolbox: H.264 encode/decode, only when calls are implemented.
-   Network: `NWPathMonitor` for connectivity changes.
-   ScreenCaptureKit: screen capture only if supported call
    functionality requires it and the feature is approved.
-   PhotosUI / NSOpenPanel / file importer: media selection.
-   UniformTypeIdentifiers: file type handling.
-   QuickLook: document and media preview where appropriate.
-   OSLog: platform logging with privacy annotations.

------------------------------------------------------------------------

## 5. User Personas and Primary Journeys

### 5.1 Primary persona: everyday desktop user

Needs to keep conversations available while working, reply quickly,
share files, and receive discreet notifications.

### 5.2 Power user

Values keyboard navigation, fast search, quick actions, predictable
window behavior, and low resource usage.

### 5.3 Privacy-conscious user

Wants local storage, explicit session controls, minimal telemetry, and
clear information about what is stored.

### 5.4 Primary user journeys

1.  First launch → onboarding → QR pairing → successful connection.
2.  App launch → restore session → load recent chats → receive live
    events.
3.  Select chat → read history → compose → send → see delivery state.
4.  Receive message while main window is hidden → native notification →
    open relevant chat.
5.  Close main window → app remains available in menu bar → reopen
    window.
6.  Network lost → show reconnecting state → recover without duplicate
    messages.
7.  Logout/unlink → confirm destructive action → remove session data
    according to policy.
8.  Update application → preserve session and local history.
9.  Sleep/wake → recover connection and media resources safely.

------------------------------------------------------------------------

## 6. Functional Scope and Feature Matrix

Feature status must be maintained in `docs/FEATURES.md`. A feature is
not considered complete merely because the underlying library exposes a
method. It must have a UI, state model, error handling, persistence
behavior, and real-account verification.

Use these statuses:

-   **Supported by library:** capability appears in the upstream project
    documentation.
-   **NIMQO planned:** intended product functionality.
-   **Verified:** tested successfully against a real account and
    documented environment.
-   **Limited:** partial support or known constraints.
-   **Unavailable:** not currently supported or not safe to ship.

Priorities:

-   **P0:** required for MVP.
-   **P1:** first releases after MVP.
-   **P2:** planned after core reliability is proven.
-   **P3:** exploratory.

Send and receive are tracked separately. A feature may be P1 to send but
P0 to receive correctly.

### 6.1 Foundation and account

  ------------------------------------------------------------------------
  Capability                                Priority Acceptance outline
  --------------------- ---------------------------- ---------------------
  First-run onboarding                            P0 Explains pairing and
                                                     unofficial-client
                                                     status

  QR pairing                                      P0 QR renders, expires,
                                                     refreshes, and
                                                     handles scan
                                                     success/failure

  Pairing code                                    P1 Available only if
                                                     verified in library
                                                     and real account
                                                     tests

  Persistent session                              P0 Session survives
                                                     normal restart

  Connection state                                P0 Connected,
                                                     connecting,
                                                     disconnected,
                                                     reconnecting, failed

  Logout/unlink                                   P0 Session removal is
                                                     explicit and
                                                     confirmed

  Session recovery                                P0 Recover from
                                                     transient failures
                                                     without corrupting
                                                     state

  Account profile                                 P1 Display available
                                                     profile identity and
                                                     avatar

  Multiple accounts                               P2 Deferred until
                                                     isolation and
                                                     lifecycle are proven
  ------------------------------------------------------------------------

### 6.2 Chats and messaging

  --------------------------------------------------------------------------
  Capability                                  Priority Acceptance outline
  ----------------------- ---------------------------- ---------------------
  Chat list                                         P0 Sorted and updated
                                                       from protocol events

  Direct messages                                   P0 Send and receive text

  Group messages                                    P0 Send and receive in
                                                       supported groups

  Message history sync                              P0 Initial sync and
                                                       incremental updates

  Message status                                    P0 Show only states
                                                       actually provided by
                                                       protocol

  Reply/quote                                       P1 Correct
                                                       quoted-message
                                                       reference

  Reactions                                         P1 Add/remove and
                                                       display reactions

  Edit message                                      P1 Only if supported and
                                                       verified

  Delete message                                    P1 Distinguish
                                                       delete-for-me and
                                                       delete-for-everyone
                                                       where supported

  Forward message                                   P1 Preserve expected
                                                       metadata and
                                                       constraints

  Star/pin/archive/mute                             P1 Implement only after
                                                       API and sync behavior
                                                       verified

  Disappearing messages                             P2 Settings and behavior
                                                       verified

  Typing/presence                                   P2 Respect privacy and
                                                       protocol availability

  Search                                            P1 Local search with
                                                       correct indexing and
                                                       privacy behavior

  Unread counts                                     P0 Accurate across app
                                                       and menu bar

  Mark as read                                      P0 Clears unread state
                                                       and syncs across
                                                       linked devices

  Read receipts                                     P1 Respect protocol and
                                                       user privacy settings

  Incoming edit/delete                              P0 Timeline applies the
                                                       change and removes
                                                       deleted content

  Incoming reactions                                P0 Stored and displayed

  Disappearing expiry                               P0 Incoming expiry is
                                                       honored locally

  Unsupported types                                 P0 Placeholder shown; raw
                                                       payload retained

  Undecryptable message                             P0 Visible state, retry
                                                       outcome handled

  Contact/display names                             P0 Push name, contact
                                                       name, avatar, group
                                                       participant names

  LID/phone identity                                P0 One person maps to
                                                       one identity

  Durable outbox                                    P0 Send survives restart
                                                       and retries safely

  Draft persistence                                 P1 Per-chat encrypted
                                                       draft

  Mentions and links                                P1 Render mentions and
                                                       safe tappable links

  Link previews                                     P2 Off by default until a
                                                       privacy policy exists

  Polls and view once                               P2 Define display and
                                                       retention policy
  --------------------------------------------------------------------------

### 6.3 Media and attachments

  ------------------------------------------------------------------------
  Capability                                Priority Acceptance outline
  --------------------- ---------------------------- ---------------------
  Image send/receive                              P0 Upload/download,
                                                     preview, error
                                                     recovery

  Video send/receive                              P1 Preview and playback
                                                     with resource limits

  Documents                                       P0 Download, open, save,
                                                     and safe file naming

  Audio                                           P1 Playback controls and
                                                     metadata

  Voice messages                                  P1 Record/playback only
                                                     after full media
                                                     pipeline is proven

  Stickers                                        P1 Render and send
                                                     supported sticker
                                                     formats

  GIF/animated media                              P2 Validate decoding and
                                                     memory behavior

  Location                                        P2 Display shared
                                                     location without
                                                     requiring external
                                                     service

  Contact cards                                   P2 Parse and display
                                                     safely

  Albums/multiple media                           P2 Preserve ordering and
                                                     grouping where
                                                     supported
  ------------------------------------------------------------------------

### 6.4 Groups, communities, channels, and status

Group metadata and participant names are part of Phase 3 because group
messaging needs them. Implement the following progressively after core
chat reliability:

-   Group creation and management, if exposed and verified.
-   Invite links and membership requests, if exposed and verified.
-   Communities and subgroups.
-   Channels/newsletters.
-   Status updates and reactions.
-   Privacy controls.

Each capability requires a separate upstream API review and test plan.
Do not assume every operation is exposed by the current version of
`whatsapp-rust`.

### 6.5 Calls

Calls are a substantial subsystem and should not block the initial
text/media release.

Potential scope:

-   One-to-one audio calls.
-   One-to-one video calls.
-   Group calls.
-   Call links.
-   Microphone/camera permissions.
-   Device selection.
-   Audio route management.
-   Call state and recovery.
-   Screen sharing, only if supported and approved.

The upstream library describes optional VoIP functionality. Video uses
application-supplied H.264 frames and therefore requires a native media
capture/rendering pipeline. Treat call functionality as a dedicated
engineering phase, not a checkbox that becomes complete by enabling a
Cargo feature. The reference client still lists group calls as disabled,
so upstream availability is not evidence of a practical implementation.

### 6.6 Native macOS features

  Feature                                                     Priority
  -------------------------------------- -----------------------------
  Menu Bar Extra                                                    P0
  Dock icon and standard app lifecycle                              P0
  Native notifications                                              P0
  Open at Login preference                                          P1
  Global keyboard shortcuts                                         P1
  Drag and drop                                                     P1
  Quick Look / file preview                                         P1
  System share integration                                          P2
  Spotlight indexing                       P2, privacy review required
  Handoff / Continuity                                              P3
  Widgets                                                           P3

------------------------------------------------------------------------

## 7. UX and Visual Design System

### 7.1 Design direction

NIMQO should use a restrained Liquid Glass visual language:

-   Glass is used for navigation, toolbars, floating controls, and
    transient surfaces.
-   Conversation content remains readable and visually stable.
-   Avoid glass effects behind every row or message.
-   Use semantic colors and system materials where possible.
-   Support light and dark appearance.
-   Respect Reduce Motion, Increase Contrast, and system
    text-size/accessibility settings.
-   Avoid custom controls when a native control provides the expected
    macOS behavior.

### 7.2 Main application layout

Recommended three-column-capable composition:

1.  **Sidebar:** app navigation and account identity.
2.  **Chat list:** search, filters, recent conversations, unread
    indicators.
3.  **Conversation:** header, message timeline, composer.

The layout should adapt to window width. On smaller windows, collapse or
replace columns rather than squeezing all three. The MVP uses two columns
because it has only Chats and Settings. Add the sidebar when more
destinations ship.

Suggested sidebar destinations:

-   Chats
-   Unread
-   Groups
-   Calls
-   Status
-   Archived
-   Settings

Only show destinations that are implemented and useful. Avoid
placeholder navigation in production.

### 7.3 Conversation design

-   Clear sender identity and message grouping.
-   Distinct outgoing and incoming message styles.
-   Readable timestamps and delivery state.
-   Reply context and reactions.
-   Attachment previews with loading/error states.
-   Virtualized or lazy-loaded long timelines. Choose between SwiftUI
    `List` and `NSTableView`/`NSCollectionView` with a Phase 0 spike
    against the reference dataset.
-   Composer with attachment, emoji/sticker, and send controls.
-   Keyboard-first send behavior with clear multiline editing rules.

### 7.4 Liquid Glass implementation rules

-   Use native SwiftUI glass APIs on macOS 26 or later, and system
    materials on macOS 14 and 15.
-   Use `GlassEffectContainer` where multiple glass elements should
    visually interact.
-   Keep glass elements grouped and purposeful.
-   Do not apply expensive blur/material effects to every message cell.
-   Avoid placing rapidly changing content inside large glass surfaces.
-   Verify contrast and legibility in light/dark mode and different
    wallpapers.
-   Profile rendering with Instruments; visual effects must not
    compromise scroll performance.

### 7.5 Menu Bar Extra

Use SwiftUI `MenuBarExtra` as the default implementation. Use AppKit
`NSStatusItem` only if a required interaction cannot be achieved
reliably with `MenuBarExtra`.

Menu bar content:

-   NIMQO status icon.
-   Optional unread count/badge where supported by platform behavior.
-   Connection state.
-   Recent conversations.
-   Quick reply, if safe and reliable.
-   Open main window.
-   Preferences.
-   Quit.

The menu bar panel should not become a second full application. Keep it
fast and focused.

### 7.6 Window and lifecycle behavior

Define and test these states explicitly:

-   Main window visible.
-   Main window hidden/minimized.
-   Menu bar panel open.
-   App active with no visible window.
-   App terminating.
-   App restarting after crash.
-   System sleep/wake.

Closing the main window should hide/close the window without
unintentionally terminating the WhatsApp session. The user must have an
explicit Quit action. Decide whether the Dock icon remains visible;
default recommendation is a normal Dock app plus Menu Bar Extra, not a
menu-bar-only agent.

Additional lifecycle requirements:

-   Allow only one running instance per user. Two processes must never
    open the same session database.
-   Verify App Nap behavior while the window is hidden. Use
    `ProcessInfo.beginActivity` only where testing shows it is needed.
-   Handle `NSWorkspace` sleep/wake notifications and `NWPathMonitor`
    changes through the connection state machine.

### 7.7 Accessibility

-   VoiceOver labels for controls and message status.
-   Full keyboard navigation.
-   Visible focus indicators.
-   Adequate contrast.
-   Reduce Motion support.
-   Dynamic text where practical.
-   No color-only status indicators.
-   Accessible QR pairing instructions and fallback explanation.

------------------------------------------------------------------------

## 8. Recommended Technical Architecture

### 8.1 Architecture decision

**Initial architecture: one native macOS app process with an embedded
Rust core.**

SwiftUI owns presentation and Apple platform APIs. Rust owns protocol
operations and domain processing. UniFFI defines a narrow, versioned
boundary.

Do not introduce a daemon, Unix socket, or custom IPC in the first
implementation. Revisit only if the app needs multiple independent
frontends, independent service lifetime, process isolation, or another
concrete requirement.

The reference client, `oxidezap/client`, uses a daemon and multiple front
ends, so its process layout should not be copied. An embedded core also
means a Rust abort terminates the UI. Keep `panic = "unwind"` in NIMQO's
release profile so UniFFI can convert panics into errors. Upstream's
release profile does not apply to dependents, so copy any tuning NIMQO
actually wants.

### 8.2 High-level component diagram

``` text
┌──────────────────────────────────────────────────────────┐
│                    NIMQO macOS App                        │
│                                                          │
│  SwiftUI Views       AppKit / macOS Services              │
│  - Sidebar           - App lifecycle                      │
│  - Chat list         - Menu Bar Extra                     │
│  - Conversation      - Notifications                      │
│  - Settings          - Keychain / permissions              │
│  - Calls UI          - AVFoundation / file panels          │
│        │                         │                        │
│        └──────── ViewModels / App Services ───────────────┘
│                              │                            │
│                         UniFFI API                         │
│                              │                            │
│  ┌───────────────────────────▼──────────────────────────┐ │
│  │                    Rust Core                          │ │
│  │                                                      │ │
│  │  Application Facade / Use Cases                      │ │
│  │       │                                              │ │
│  │  Session Manager ─ Event Dispatcher ─ Sync Engine    │ │
│  │       │                  │                           │ │
│  │  whatsapp-rust adapter / protocol client             │ │
│  │       │                                              │ │
│  │  Persistence adapters / Media pipeline / Retry       │ │
│  └──────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────┘
```

### 8.3 Technology choices

  -----------------------------------------------------------------------
  Layer                   Choice                  Responsibility
  ----------------------- ----------------------- -----------------------
  UI                      SwiftUI                 Native interface

  Platform integration    AppKit                  Lifecycle and missing
                                                  native hooks

  Language                Swift 6                 UI and platform
                                                  services

  Core                    Rust                    Protocol/domain engine

  WhatsApp protocol       `whatsapp-rust`         WhatsApp Web protocol
                                                  implementation

  Bridge                  UniFFI                  Swift/Rust bindings

  Async                   Tokio, subject to       Background async work
                          upstream runtime        
                          integration             

  Serialization           Serde                   Internal
                                                  DTOs/configuration

  App database            SQLCipher               NIMQO-owned message
                                                  history and app metadata

  Search                  FTS5 inside SQLCipher   Local message search

  Secret storage          macOS Keychain          Key material and
                                                  sensitive tokens

  Logging                 OSLog + Rust `log`      Diagnostics; upstream
                          bridge                  `tracing` is optional

  Media                   Rust protocol layer +   Transfer, capture,
                          Apple media frameworks  playback

  Build                   Cargo + Xcode           Native build pipeline

  Code quality            rustfmt, Clippy,        Mandatory local gate
                          SwiftLint, SwiftFormat  in `pre-push` hook

  Distribution            Developer ID signing +  Outside-App-Store
                          notarization            distribution
  -----------------------------------------------------------------------

Do not add a dependency just because it is common. Every dependency
needs a purpose, maintenance review, license review, and update
strategy.

### 8.4 Rust crate strategy

Start with a small workspace. Split crates only when ownership
boundaries are clear. `nimqo-storage` and `nimqo-media` become separate
crates only when their size or ownership justifies it.

``` text
rust/
├── Cargo.toml
├── Cargo.lock
└── crates/
    ├── nimqo-core/       # domain, use cases, events, errors, storage, media
    ├── nimqo-whatsapp/   # upstream adapter, session, protocol event mapping
    └── nimqo-ffi/        # UniFFI API and DTO conversion
```

Generated Swift bindings are build output and are excluded from code
quality metrics.

The `nimqo-whatsapp` crate is the only layer that should depend directly
on upstream `whatsapp-rust`. This adapter protects the rest of NIMQO
from upstream API churn.

### 8.5 Swift project structure

``` text
NIMQO/
├── App/
│   ├── NIMQOApp.swift
│   ├── AppDelegate.swift
│   └── AppLifecycle.swift
├── Core/
│   ├── Bridge/
│   ├── Models/
│   ├── Services/
│   ├── State/
│   └── Utilities/
├── Features/
│   ├── Onboarding/
│   ├── Pairing/
│   ├── Chats/
│   ├── Conversation/
│   ├── Contacts/
│   ├── Groups/
│   ├── Calls/
│   ├── Status/
│   ├── Search/
│   └── Settings/
├── MenuBar/
├── DesignSystem/
│   ├── Components/
│   ├── Materials/
│   ├── Typography/
│   ├── Colors/
│   └── Icons/
├── Platform/
│   ├── Notifications/
│   ├── Keychain/
│   ├── Media/
│   ├── Permissions/
│   └── FileAccess/
├── Resources/
└── Tests/
```

### 8.6 Data ownership

-   Rust owns protocol session state and protocol event processing.
-   Swift owns presentation state, window state, and Apple framework
    interactions.
-   NIMQO's database is the **source of truth for message history**.
    Upstream migrations contain protocol tables, such as sessions, keys,
    `group_metadata`, `sent_messages`, and `pending_inbound_messages`, but
    no `messages`, `chats`, or `contacts` tables. History must be
    materialized from the event stream.
-   Avoid storing the same authoritative state independently in Swift
    and Rust.
-   SwiftUI must not directly access the upstream WhatsApp client.
-   The Swift/Rust API should expose stable NIMQO domain models, not
    upstream library types.

### 8.7 UniFFI boundary

Expose a small API surface:

-   `NimqoClient` lifecycle.
-   `connect`, `disconnect`, `pair`, `logout`.
-   `get_connection_state`.
-   `list_chats`, `get_messages`.
-   `send_text_message`.
-   `send_media`.
-   `mark_read`.
-   `search_messages`.
-   Event subscription for incoming messages, status changes, sync
    progress, and errors.

Use UniFFI-supported async functions and callback/stream patterns
appropriate to the pinned UniFFI version. Confirm generated Swift
concurrency behavior in a proof of concept before finalizing the
interface.

Important constraints:

-   Do not pass arbitrary upstream Rust structures across FFI.
-   Use explicit DTOs and typed errors.
-   Avoid high-frequency FFI calls for every UI redraw.
-   Batch events where appropriate.
-   Define cancellation and shutdown semantics.
-   Ensure callbacks cannot outlive the client/session unexpectedly.
-   Never block the Swift main actor while Rust performs network or
    database work.

------------------------------------------------------------------------

## 9. Upstream `whatsapp-rust` Integration Plan

### 9.1 Repository and version policy

Upstream repository: <https://github.com/oxidezap/whatsapp-rust>

The upstream README currently documents the `0.7` dependency line and
describes QR/pairing-code authentication, persistent sessions, encrypted
messaging, media, groups, communities, newsletters, status, contacts,
privacy controls, and optional VoIP functionality. The release notes
also describe breaking API changes before 1.0.

**Do not treat this as a guarantee that every feature is
production-ready or that every API has been verified in NIMQO.**

Upstream's `agent_docs/support.md` lists **macOS as unqualified**, with no
maintained macOS runner. NIMQO's local macOS test runs and real-account
tests are therefore the only evidence of macOS support.

Upstream's MSRV is Rust 1.95, and its workspace tooling uses a pinned
nightly. Release v0.7.0 is 533 commits behind `main` as of this document.

Before implementation:

1.  Inspect the exact upstream tag/commit.
2.  Read README, docs, examples, feature flags, migration notes, and
    known issues.
3.  Record the selected commit in `Cargo.lock`.
4.  Build a minimal pairing/send/receive proof of concept.
5.  Record supported APIs and known limitations in
    `docs/UPSTREAM-COMPATIBILITY.md`.
6.  Upgrade deliberately, not automatically.

### 9.2 Dependency strategy

-   Pin an exact Git revision of `main` that passes the proof of concept.
    Prefer a tagged release once it contains the required server
    compatibility. Reassess the choice at each upgrade.
-   Disable upstream default features and select them explicitly, because
    the defaults include plain bundled SQLite.
-   The release script must reject `tracing-pii`, `danger-skip-tls-verify`, `test-support`,
    and `bench-harness` in release builds.
-   Commit `Cargo.lock` for the application.
-   Avoid floating Git branches in release builds.
-   Review transitive dependency changes.
-   Run `cargo audit`, `cargo deny`, formatting, and Clippy in the local
    gate.
-   Track upstream releases and breaking changes.
-   Keep the adapter layer small and well tested.

### 9.3 Proof-of-concept exit criteria

Before building the full UI, prove:

-   Pairing works with a dedicated test account.
-   Session persistence works after process restart.
-   Incoming text message events are delivered.
-   Outgoing text messages work.
-   Reconnect works after network interruption.
-   A media transfer works.
-   Protocol and app databases open through SQLCipher with a Keychain key.
-   `InboundDurabilityHook` commits a message before acknowledgement and
    redelivery after a crash is deduplicated.
-   Network behavior through a proxy, VPN, and custom root CA is recorded.
-   Session/database files are located where expected.
-   Shutdown is clean.
-   Rust can be called from Swift through generated UniFFI bindings.
-   No blocking call freezes the UI.

### 9.4 Upstream limitations register

Maintain a table with:

-   Feature.
-   Upstream API or module.
-   Cargo feature flag.
-   NIMQO adapter implementation.
-   Real-account test result.
-   Known limitation.
-   Last verified upstream commit.
-   Regression test reference.

------------------------------------------------------------------------

## 10. Session, Event, and State Management

### 10.1 Connection state machine

Use a defined state machine, not scattered Boolean flags.

``` text
App launch ──► NotPaired (no stored session)
App launch ──► Connecting (stored session)

NotPaired ── pair ──► Pairing
Pairing ── success ──► Connecting
Pairing ── error / QR codes exhausted ──► NotPaired

Connecting ── connected ──► Connected
Connecting ── transient failure ──► Reconnecting
Connecting ── terminal failure ──► Terminal state

Connected ── network or stream interruption ──► Reconnecting
Connected ── user logout ──► Disconnecting ──► NotPaired
Reconnecting ── success ──► Connected
Reconnecting ── terminal failure ──► Terminal state

Terminal states:
  LoggedOut          (unlinked remotely; explicit re-pair)
  StreamReplaced     (another session took over; do not auto-reconnect loop)
  TemporaryBan       (show expiry; do not retry before it)
  ClientOutdated     (protocol rejected; prompt for an update)
  Failed             (unclassified; diagnostics available)
```

`Offline` is an input from `NWPathMonitor`. It pauses reconnect attempts
rather than counting as a failure. Map upstream `Connected`, `Disconnected`,
`LoggedOut`, `StreamReplaced`, `TemporaryBan`, `ClientOutdated`,
`ConnectFailure`, `StreamError`, and `PairingQrCodesExhausted` explicitly.

Additional states may include `Syncing`, `Suspended`, or `ShuttingDown`
where justified.

### 10.2 Event model

Define typed domain events, for example:

-   `ConnectionStateChanged`
-   `PairingQrCodeUpdated`
-   `PairingCodeUpdated`
-   `SyncProgressUpdated`
-   `ChatUpserted`
-   `MessageReceived`
-   `MessageUpdated`
-   `MessageStatusChanged`
-   `ReactionUpdated`
-   `ContactUpdated`
-   `GroupUpdated`
-   `AppStateChanged` for mute, pin, archive, star, and read state
-   `MessageUndecryptable`
-   `MediaTransferProgress`
-   `CallStateChanged`
-   `ClientError`

Events should be ordered where order matters, carry stable identifiers,
and be safe to process more than once.

### 10.3 Idempotency and duplicate handling

-   Key messages by `(chat, sender, id)`, enforced with a database unique
    constraint. Upstream stanza IDs are only unique within a chat and
    sender.
-   Store identities so a LID and phone number resolve to one person.
-   Make event handlers idempotent.
-   Upsert rather than blindly insert where appropriate.
-   Deduplicate history sync and live events.
-   Preserve ordering metadata when provided.
-   Do not infer delivery/read states from timing.

### 10.4 Backpressure

-   Use bounded queues for high-volume events.
-   Coalesce replaceable state events such as progress updates.
-   Do not drop message events silently.
-   Define what happens when the UI is not subscribed or is suspended.
-   Register `InboundDurabilityHook`. Upstream's default is at-most-once:
    a message is acknowledged after decryption and is lost if the app
    crashes before persisting it. The hook defers acknowledgement until
    NIMQO commits, and must be idempotent.
-   Evaluate `with_history_sync_capture_hook` for history durability in
    Phase 0. History cannot be assumed to be fetchable again.
-   Keep the raw decrypted payload of unsupported message types so a later
    release can render them.

### 10.5 Outbox

-   Persist outgoing messages before the first network attempt.
-   Retry with the same message ID after restart or disconnect.
-   Show queued, failed, and uncertain states without inventing delivery.
-   Limit automatic retries, and let the user retry or discard a failure.
-   Encrypt outbox content like all other message data.

### 10.6 Shutdown

-   Stop accepting new operations.
-   Cancel or finish in-flight work according to policy.
-   Flush application-owned database writes.
-   Persist session state using upstream-supported behavior.
-   Close media devices and transports.
-   Release event subscriptions.
-   Avoid forceful termination as normal shutdown behavior.

------------------------------------------------------------------------

## 11. Data Storage and Retention

### 11.1 Storage categories

Separate these data classes:

1.  **Protocol/session data:** device identity, cryptographic state,
    protocol cache.
2.  **Application metadata:** preferences, local chat index,
    pinned/hidden UI state.
3.  **Message metadata/history:** only what is needed and permitted by
    the upstream client and product behavior.
4.  **Media files:** downloaded attachments and thumbnails.
5.  **Logs and diagnostics:** minimized, redacted, short retention.

### 11.2 Storage location

Use the appropriate macOS Application Support and Caches directories. Do
not store data in the application bundle or an arbitrary working
directory.

Suggested logical structure:

``` text
~/Library/Application Support/NIMQO/
├── protocol/
├── database/
├── media/
├── thumbnails/
└── migrations/

~/Library/Caches/NIMQO/
└── transient/

~/Library/Logs/NIMQO/
└── diagnostics/
```

Exact paths should be obtained through Apple APIs, not hardcoded. Exclude
session, database, and media directories from Time Machine with
`isExcludedFromBackup`. A restored Signal state is stale and can break
sessions, and backups would extend the life of protected data. Debug and
locally built variants must use a separate bundle identifier, data
directory, and Keychain item.

### 11.3 Encryption at rest

**Decision: encryption is mandatory from the first persisted byte.** There
is no plaintext mode, no plaintext-to-encrypted migration, and no silent
fallback. If the key is unavailable, NIMQO fails closed and explains the
problem without opening or recreating data.

**Key management**

-   Generate a 256-bit master key with the system CSPRNG on first run.
-   Store it in the Keychain as device-only and non-synchronizable, with
    access limited to NIMQO's signing identity. Verify the data protection
    Keychain, its entitlement needs, and access after login in Phase 0.
-   Derive independent keys with HKDF for the protocol database, app
    database, and media. Never reuse one key across them.
-   Never write keys to disk, logs, environment variables, crash reports,
    or generated SQL that may be logged. Zeroize Rust copies with
    `zeroize`, and keep any Swift copy as short-lived as possible.
-   Do not add a passphrase, cloud escrow, or recovery backdoor in the
    initial release. Losing the Keychain item means re-pairing and losing
    local history. Disclose this during onboarding.
-   Rotation in the first release is logout/reset. Add `PRAGMA rekey` only
    with a crash-safe, tested procedure and an ADR.

**Databases**

-   Use SQLCipher for both databases, built through `libsqlite3-sys`
    `bundled-sqlcipher`. Only one `libsqlite3-sys` may exist in the
    dependency graph, so disable upstream's `bundled-sqlite` and
    `sqlite-storage-bundled` features.
-   Key upstream's store through
    `SqliteDatabaseConfig::with_connection_init`. It runs before WAL setup
    and migrations, and must apply the key and then verify it by reading
    `sqlite_master`.
-   Use SQLCipher's raw-key form so the 256-bit key skips passphrase
    derivation and never appears as a passphrase.
-   Keep `temp_store = memory` and leave `mmap_size` off unless a reviewed
    measurement justifies a change.
-   Keep FTS5 search data inside the encrypted database, and confirm FTS5
    is enabled in the SQLCipher build.
-   Build with CommonCrypto. The build script can select a detected
    OpenSSL instead, so a release gate must confirm with `otool -L` that
    no external `libcrypto` is linked.

**Media and temporary files**

-   Encrypt downloaded media, thumbnails, avatars, and drafted attachments
    using a reviewed streaming AEAD construction with per-file keys. Select
    the construction in an ADR; do not invent a format.
-   Support range access for large media, and decrypt into memory where
    practical. Cache decrypted images only in bounded memory.
-   Plaintext is allowed only for an explicit user action: Quick Look,
    opening externally, or Save As. Use a per-user `0700` temporary
    directory, remove files when finished, and purge leftovers on launch.
    Exported files are outside NIMQO's protection.

**Required tests**

-   `PRAGMA cipher_version` returns a value in release builds.
-   Database files do not begin with `SQLite format 3`.
-   A wrong or missing key fails closed and leaves data unchanged.
-   Known message text and media bytes are not found by scanning the data
    directory, including WAL files, after a real send/receive flow.
-   Logout destroys keys first, then files, and a crash between the steps
    recovers safely.

**Residual risks to disclose**

-   Code running as the user can read process memory, and it may reach the
    key if it can act as NIMQO or the user approves Keychain access.
-   macOS can retain notification content. Offer a setting that hides
    sender and message text, and document what the OS stores.
-   Pasteboard contents, screenshots, and exported files are outside
    NIMQO's protection.
-   FileVault remains recommended as an additional layer, not a substitute.

### 11.4 Database design

NIMQO's own database may contain tables such as:

-   `schema_migrations`
-   `chats`
-   `messages`
-   `contacts`
-   `message_attachments`
-   `message_reactions`
-   `local_preferences`
-   `search_index`

These are conceptual entities, not a final schema. Do not duplicate
protocol tables that upstream already owns, such as sessions, keys, and
group metadata, without a clear read-model requirement. Messages, chats,
and contacts belong to NIMQO's database. Add `outbox` and raw payload
storage for unsupported message types.

### 11.5 Search

-   Use FTS5 inside the encrypted database for searchable message content.
-   Index only fields needed for search.
-   Define deletion and reindex behavior.
-   Keep search local by default.
-   Avoid Spotlight indexing until privacy and deletion semantics are
    clear.

### 11.6 Retention and deletion

-   Provide clear logout and local-data reset flows.
-   Explain what logout deletes and what remains.
-   Remove media and thumbnails according to user-selected retention
    policy.
-   Handle failed deletions safely and report them.
-   Do not promise forensic secure deletion on APFS/SSD. Destroying keys
    first is the practical guarantee: remaining encrypted blocks become
    unreadable.
-   Provide export only after a clear format and privacy model is
    defined.

------------------------------------------------------------------------

## 12. Security and Privacy Requirements

### 12.1 Threat model

Protect against:

-   Accidental exposure of session files.
-   Other local users reading application data.
-   Secret leakage through logs or crash reports.
-   Malicious or malformed media and documents.
-   Dependency compromise.
-   Insecure update/package delivery.
-   FFI memory/lifecycle bugs.
-   Unintended network requests or telemetry.
-   Malicious contributions to a public repository.
-   Attachments that execute or disguise their file type.
-   Data remaining after logout/reset.

NIMQO cannot protect against a fully compromised macOS account, kernel,
or device. State this limitation accurately.

### 12.2 Security controls

-   Store secrets in Keychain.
-   Apply least-privilege filesystem permissions.
-   Validate file paths and prevent path traversal.
-   Apply size/type limits to media and documents.
-   Avoid shell invocation for user-controlled filenames or content.
-   Avoid unsafe Rust unless necessary and reviewed.
-   Use typed errors and avoid leaking secrets in error messages.
-   Redact phone numbers, message bodies, tokens, and identifiers from
    logs.
-   Use TLS as provided by the protocol/network stack; do not disable
    certificate validation.
-   Verify signed update artifacts.
-   Review all native dependencies and bundled binaries.
-   Keep debug endpoints and test credentials out of release builds.
-   Apply `com.apple.quarantine` to files opened or saved from attachments
    so Gatekeeper evaluates them.
-   Sanitize attachment names, including path separators, control
    characters, and right-to-left overrides.
-   Do not fetch link previews or remote content automatically.
-   Use the hardened runtime and only the entitlements each feature needs.

### 12.3 Logging

Use structured logging with levels:

-   Error
-   Warn
-   Info
-   Debug
-   Trace

Release default should be conservative. Message bodies, media content,
pairing QR payloads, session tokens, encryption keys, and personal
identifiers must never be logged.

Provide a user-initiated diagnostic export with a preview/redaction
step.

### 12.4 Permissions

Request microphone, camera, screen capture, and notification
permissions only when the user invokes the relevant feature or when the
product flow clearly requires them. Explain why the permission is
needed. macOS Contacts access is not required, because contact data comes
from WhatsApp sync. Add it only for an approved feature.

### 12.5 Security review gates

Before beta:

-   Dependency/license review.
-   Secret storage review.
-   Local database and media storage review.
-   FFI ownership/lifecycle review.
-   Log redaction review.
-   File handling review.
-   Update/signing review.
-   Threat-model review.
-   Account/session reset test.
-   Encryption test suite in Section 11.3.
-   Independent review of key handling and the media format.

### 12.6 Open source security

-   Publish `SECURITY.md` with GitHub private vulnerability reporting and
    a response target.
-   Enable secret scanning, push protection, Dependabot, and CodeQL or
    equivalent.
-   The repository is public from its first commit, so every push is a
    publication. Run a secret scanner (for example gitleaks) as a
    `pre-push` hook, and keep GitHub push protection enabled. A leaked secret is rotated, never just deleted from
    history.
-   Never commit test account data, session files, or real conversation
    fixtures.
-   Contributed code is reviewed before it is run locally with any
    credential available. Signing credentials stay in the maintainer's
    Keychain and never enter the repository.
-   Signing and notarization run only on the maintainer's machine.
-   Publish release checksums, build provenance, and an SBOM.
-   Security depends on keys and OS protections, never on hidden source.

------------------------------------------------------------------------

## 13. Performance and Resource Strategy

### 13.1 Performance philosophy

Performance goals are measured, not asserted. Do not optimize based on
guesses or use arbitrary limits as proof of efficiency.

### 13.2 Initial targets

These are provisional engineering targets for a reference Apple Silicon
Mac and must be revised after a baseline build:

  -----------------------------------------------------------------------
  Metric                                                   Initial target
  ------------------------------ ----------------------------------------
  Cold launch to usable window                              ≤ 2.0 seconds

  Idle CPU after sync settles            Near 0%; measured over 5 minutes

  Idle memory                             Aim for ≤ 100 MB where feasible

  UI scrolling                          Consistent 60 FPS or better where
                                                      display supports it

  Main-thread stalls               No avoidable blocking network/database
                                                                     work

  Message UI update              Perceived immediate response after event
                                                                 delivery

  Reconnect                          Recover automatically where protocol
                                                                  permits

  Battery                            No unnecessary polling or busy loops
  -----------------------------------------------------------------------

Do not make a release claim based on a single measurement or an empty
test database. The reference dataset starts at about 75,000 messages
across 1,000 chats, matching the scale of the reference client's memory
workload, plus encrypted media. Measure SQLCipher's overhead explicitly,
and add targets for send latency, chat-open time, and app size.

### 13.3 Optimization techniques

-   One long-lived protocol client/session per account.
-   One controlled async runtime strategy.
-   Avoid repeated runtime creation.
-   Bounded task and event queues.
-   Pagination for chat history.
-   Lazy loading for media and long timelines.
-   Thumbnail generation and caching.
-   Debounced search.
-   Batch database writes when safe.
-   Avoid excessive SwiftUI view invalidation.
-   Stable view identity for message rows.
-   Avoid expensive glass effects in scrolling cells.
-   Avoid polling when protocol events are available.
-   Profile Rust allocations and SwiftUI rendering separately.

### 13.4 Instruments and profiling

Use:

-   Time Profiler.
-   Allocations.
-   Leaks.
-   Points of Interest.
-   Network.
-   Energy Log.
-   SwiftUI Instruments tools where available.
-   Rust benchmarks and allocation profiling where useful.

Record benchmark hardware, OS version, build configuration, dataset
size, and test duration.

------------------------------------------------------------------------

## 14. Error Handling and Resilience

Define a stable error taxonomy:

-   Pairing/authentication error.
-   Session invalidation or remote logout.
-   Session replaced by another connection.
-   Network unavailable.
-   Protocol incompatibility or outdated client.
-   Temporary ban.
-   Rate limit/throttling.
-   Encryption key unavailable or invalid.
-   Undecryptable message.
-   Media upload/download error.
-   Storage/database error.
-   Permission denied.
-   Unsupported feature.
-   Internal error.

Requirements:

-   User-facing messages should be understandable and actionable.
-   Diagnostic details should be available without exposing secrets.
-   Retry only transient operations.
-   Use exponential backoff with jitter where appropriate.
-   Avoid retry storms.
-   Respect upstream rate limiting and server responses.
-   Preserve message state when send outcome is uncertain.
-   Do not report a message as sent until the protocol operation has
    reached the appropriate confirmed state.
-   Distinguish queued, submitted, delivered, and read only where those
    states are actually known.

------------------------------------------------------------------------

## 15. Testing Strategy

### 15.1 Test layers

**Rust unit tests**

-   State machine.
-   Domain rules.
-   Message mapping.
-   Event deduplication.
-   Retry policy.
-   Storage migrations.
-   Error mapping.

**Rust integration tests**

-   Adapter behavior.
-   Session lifecycle.
-   Database behavior.
-   Mock transport scenarios where possible.

**UniFFI contract tests**

-   Generated API compiles.
-   DTO conversion.
-   Typed error conversion.
-   Async behavior.
-   Callback lifetime and cancellation.

**Swift unit tests**

-   ViewModel state.
-   Navigation.
-   Notification routing.
-   UI formatting.
-   Search/filter logic.

**UI tests**

-   Onboarding.
-   Pairing state.
-   Chat list.
-   Send message.
-   Open notification.
-   Menu bar behavior.
-   Settings and logout.

**Real-account tests**

-   Pairing and reconnect.
-   Direct messages.
-   Group messages.
-   Media transfers.
-   History sync.
-   Receipts/reactions.
-   Calls, only when implemented.

Use dedicated test accounts and consenting participants. Do not test
against unrelated users or automate activity that violates platform
policies. Real-account tests are never part of the default gate. Contributors must be
able to run the default test suite with no account or secret, and
fixtures must be synthetic.

### 15.2 Required regression scenarios

-   No network at launch.
-   Network drops during send.
-   Network drops during media transfer.
-   Mac sleeps while connected.
-   Mac wakes after extended sleep.
-   App is force-quit and relaunched.
-   Session expires or is invalidated.
-   QR expires before scanning.
-   Duplicate events arrive.
-   History sync overlaps with live messages.
-   Database migration fails.
-   Disk is nearly full.
-   Media file is malformed or oversized.
-   Notification permission is denied.
-   Main window is closed while session remains active.
-   User logs out during an active transfer.
-   Crash after decrypt but before commit; message is redelivered once.
-   Outgoing message survives restart without being sent twice.
-   Keychain item is missing, denied, or wrong; app fails closed.
-   Second app instance is launched.
-   Message is edited, deleted, or expires after being stored.
-   Linked device is removed from the phone.
-   Session is replaced or temporarily banned.
-   App Nap and hidden-window behavior over a long idle period.
-   Lowest supported OS (macOS 14) without Liquid Glass.

### 15.3 Definition of Done

A feature is done only when:

-   Requirements are documented.
-   UI and error states are implemented.
-   Unit/integration tests pass.
-   Real-account behavior is verified where required.
-   Accessibility is checked.
-   Logs are privacy-safe.
-   Performance impact is measured for expensive paths.
-   Documentation is updated.
-   No unresolved critical/high defect remains.
-   The local quality gate (Section 16.6) passes.
-   No new persisted data bypasses encryption.

------------------------------------------------------------------------

## 16. Build, Quality Gate, Signing, and Release Engineering

### 16.1 Local development

Required tooling:

-   Xcode and the matching macOS SDK.
-   Stable Rust toolchain at or above upstream's MSRV (currently 1.95),
    pinned in `rust-toolchain.toml`.
-   Cargo.
-   UniFFI CLI version pinned to the crate version.
-   SwiftLint and SwiftFormat, with committed configurations.
-   `cargo fmt`, Clippy with warnings denied, audit, and deny checks.
-   `cargo-llvm-cov`, `cargo-audit`, `cargo-deny`, and gitleaks.
-   The versioned `pre-push` hook is authoritative. There is no hosted CI.

### 16.2 Build pipeline

1.  Check formatting and lint.
2.  Run Rust unit tests.
3.  Build Rust library for the target architecture.
4.  Generate Swift bindings.
5.  Build Swift application.
6.  Run Swift tests.
7.  Run integration/UI tests where available.
8.  Run the local quality gate and stop on any failure.
9.  Verify release feature flags and SQLCipher linkage.
10. Assemble app bundle.
11. Sign nested binaries and frameworks.
12. Sign the app.
13. Notarize and staple for Developer ID distribution.
14. Verify Gatekeeper assessment and clean-machine installation.

### 16.3 Reproducibility

-   Commit Cargo.lock.
-   Pin Rust toolchain.
-   Pin UniFFI generator.
-   Record Xcode/SDK versions in release notes.
-   Avoid unpinned downloads in release scripts.
-   Generate an SBOM or dependency inventory for release artifacts.
-   Preserve build logs and signing/notarization results.

### 16.4 Distribution options

**Initial recommendation:** public GitHub source plus a Developer ID
signed and notarized DMG on GitHub Releases. Document how to build from
source. Local builds use a separate bundle identifier and data directory
so they never access an official build's Keychain item.

Mac App Store distribution requires a separate review of sandboxing,
entitlements, background behavior, and all third-party protocol/library
requirements. Do not assume the current architecture is App Store
compliant.

### 16.5 Update strategy

-   Use Sparkle unless the Phase 7 review finds a better option. Its
    update feed is the only non-WhatsApp network request by default, and
    this must be disclosed.
-   Use signed release artifacts.
-   Verify update signatures before installation.
-   Do not silently replace app files without a verified update process.
-   Preserve user data during upgrades.
-   Support recovery from failed updates. Application rollback must not
    restore stale Signal state: use a pre-migration backup only if the
    migration fails before any reconnect, and otherwise require re-pairing.
-   Encrypt migration backups and delete them after verification.
-   Maintain an emergency release runbook for `ClientOutdated` and
    protocol breakage, covering upstream upgrade, regression tests,
    release, and user communication.

### 16.6 Open source and code quality gate

There is no hosted CI and no SonarQube; GitHub Actions is unavailable and
SonarQube's free Docker edition cannot analyze Swift. Quality is enforced
by a local gate and by review.

**The local gate is mandatory.** It lives in `.githooks/pre-push`, enabled
with `git config core.hooksPath .githooks`, and blocks the push on failure.
Each check runs once its code exists:

-   gitleaks over the commits being pushed.
-   `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`
    (pedantic lints enabled per crate), and `cargo test`.
-   `cargo audit` and `cargo deny check`.
-   SwiftFormat lint, SwiftLint in strict mode, and Xcode tests with
    warnings treated as errors.
-   The release script additionally checks release feature flags and
    SQLCipher linkage (Section 11.3).

Code standards:

-   Do not bypass the hook with `--no-verify`. A broken check is fixed or
    removed in its own reviewed commit.
-   No `#[allow]` or `swiftlint:disable` without a comment stating why.
-   Coverage is measured with `cargo llvm-cov` and Xcode, and reported in
    pull requests. Domain, storage, encryption, and state machine code
    aims for at least 80% line coverage; this is reviewed, not a hook
    threshold.
-   Keep functions small and logic in testable view models and services,
    not in views.
-   Avoid `unsafe` Rust outside FFI-generated code. Any other use needs a
    `SAFETY` comment and review.
-   Avoid `@unchecked Sendable` and `nonisolated(unsafe)` in Swift unless
    documented.
-   Contributors run the same hook. The maintainer runs it again on a pull
    request's head before merging, after reviewing the code.
-   Automated checks complement review and do not replace security review,
    real-account tests, or Instruments profiling.

Public repository requirements:

-   `LICENSE`, `THIRD-PARTY-NOTICES`, `README`, `CONTRIBUTING`,
    `CODE_OF_CONDUCT`, `SECURITY`, and issue and pull request templates.
-   License: **MIT** (decided), matching upstream. Record it in ADR 0007
    and add `LICENSE` in the first commit. Verify every bundled
    dependency is MIT-compatible and list its notice in
    `THIRD-PARTY-NOTICES`, including SQLCipher Community Edition
    (BSD-style).
-   The README states the unofficial status, account risk, and verified
    feature matrix.
-   Use conventional commits and the Developer Certificate of Origin.
-   A contributor can build and run tests from a clean clone using
    documented commands.

------------------------------------------------------------------------

## 17. Development Roadmap and Milestones

The roadmap is milestone-based. Calendar estimates should be added only
after the proof of concept reveals integration complexity.

### Phase 0 --- Discovery and technical validation

**Deliverables**

-   Upstream API/feature audit.
-   License and dependency inventory.
-   macOS 14 toolchain and fallback verification.
-   UniFFI proof of concept.
-   Pair/send/receive/reconnect prototype.
-   SQLCipher and Keychain spike with upstream `with_connection_init`.
-   Durability and history capture hook spike.
-   Timeline rendering spike.
-   Media encryption ADR.
-   Architecture decision records.

**Exit criteria**

-   Rust library can be called from Swift.
-   Real test account pairing and basic messaging work.
-   Runtime/lifecycle strategy is proven.
-   Critical upstream limitations are documented.
-   Upstream runs correctly on macOS, despite its unqualified status.
-   Encrypted storage works end to end. If it cannot, stop and re-plan
    before Phase 1.

### Phase 1 --- Foundation

**Deliverables**

-   Xcode project and Rust workspace.
-   Reproducible local build.
-   UniFFI generation script.
-   Logging and error model.
-   Local quality gate hook and public repo documents.
-   Encrypted storage layer and Keychain key lifecycle.
-   App lifecycle and window skeleton.
-   Basic design tokens and navigation shell.

**Exit criteria**

-   One command or documented command sequence builds the app.
-   Generated bindings are reproducible.
-   No protocol logic is embedded in SwiftUI views.
-   The local quality gate runs and passes on `main`.
-   The encryption test suite runs in the local gate.

### Phase 2 --- Pairing and session lifecycle

**Deliverables**

-   Onboarding.
-   QR pairing.
-   Connection state machine.
-   Persistent session.
-   Reconnect and sleep/wake handling.
-   Logout/reset with key destruction.
-   Single-instance guard, App Nap, and network monitoring.

**Exit criteria**

-   Pair once, restart, reconnect.
-   Correct error states and session reset.
-   No UI blocking.

### Phase 3 --- Core messaging

**Deliverables**

-   Chat list.
-   Conversation view.
-   Text send/receive.
-   History sync.
-   Unread counts.
-   Receipts and message status where supported.
-   Encrypted local message store with durability hook.
-   Outbox and mark as read.
-   Contacts, display names, avatars, group metadata, and LID/phone identity.
-   Incoming edits, deletes, reactions, expiry, and unsupported placeholders.

**Exit criteria**

-   Core direct and group chat workflows pass real-account tests.
-   Duplicate events do not duplicate messages.
-   Large histories do not freeze the UI.

### Phase 4 --- Media and productivity

**Deliverables**

-   Image/document transfer.
-   Audio/video preview.
-   Reactions and replies.
-   Search.
-   Drag/drop.
-   Native notifications.
-   Keyboard shortcuts.

**Exit criteria**

-   Media error/retry paths work.
-   Search remains local.
-   Notifications route to the correct conversation.

### Phase 5 --- Native macOS polish

**Deliverables**

-   Liquid Glass on macOS 26+ and material fallback on macOS 14/15.
-   Menu Bar Extra.
-   Background connection behavior.
-   Settings and appearance preferences.
-   Accessibility pass.
-   Window restoration and keyboard navigation.

**Exit criteria**

-   Main window and menu bar behavior are stable.
-   Light/dark and accessibility settings work.
-   Visual effects meet performance targets.

### Phase 6 --- Advanced WhatsApp features

**Deliverables, subject to upstream verification**

-   Groups and group administration.
-   Communities.
-   Channels/newsletters.
-   Status.
-   Privacy controls.
-   Stickers and advanced media.
-   Calls and screen sharing.

**Exit criteria**

-   Each feature has its own test matrix and documented support status.
-   Unsupported operations are clearly disabled or explained.

### Phase 7 --- Security, performance, and beta

**Deliverables**

-   Threat-model review.
-   Encryption audit and independent review of key handling.
-   Dependency audit.
-   Performance baseline.
-   Crash/recovery testing.
-   Signed beta build.
-   User-facing disclaimer and privacy documentation.

**Exit criteria**

-   No known critical/high security issues.
-   Core workflows pass regression.
-   Resource usage is measured and acceptable.
-   Beta installation/update/uninstall tested.
-   Full history secret scan passes on the public repository.
-   macOS 14 verified on a real machine or VM.

### Phase 8 --- Release

**Deliverables**

-   Release candidate.
-   Signed/notarized DMG.
-   Release notes.
-   Known limitations.
-   Privacy and support documentation.
-   Update/recovery procedure and emergency release runbook.
-   Community and security documents complete in the public repository.

**Exit criteria**

-   Clean installation and upgrade verified.
-   Release artifacts, checksums, provenance, and SBOM published.
-   The local quality gate passes on the release commit.
-   Known limitations are disclosed.

------------------------------------------------------------------------

## 18. Suggested Repository Documentation

Keep these documents in the repository and update them as decisions
change. Start with the following, and add others when they have real
content:

``` text
README.md
LICENSE
THIRD-PARTY-NOTICES
CONTRIBUTING.md
CODE_OF_CONDUCT.md
SECURITY.md
.githooks/pre-push
docs/
├── ARCHITECTURE.md
├── FEATURES.md
├── PRIVACY.md
├── ENCRYPTION.md
├── UPSTREAM-COMPATIBILITY.md
└── ADR/
    ├── 0001-native-swiftui-rust-core.md
    ├── 0002-uniffi-boundary.md
    ├── 0003-embedded-core-vs-daemon.md
    ├── 0004-encryption-and-key-management.md
    ├── 0005-minimum-macos-14.md
    ├── 0006-media-encryption-format.md
    └── 0007-license.md
```

### 18.1 Architecture Decision Records

Every major decision should include:

-   Context.
-   Decision.
-   Alternatives considered.
-   Consequences.
-   Security/performance implications.
-   Date and status.

Do not silently change architecture through implementation details.

------------------------------------------------------------------------

## 19. Initial Backlog

### Epic A --- Repository and toolchain

-   [x] Create public GitHub repository (`wprimadi/nimqo`).
-   [x] Choose license: MIT.
-   [ ] Enable push protection, secret scanning, and a gitleaks hook
    before the first push.
-   [ ] Add `LICENSE` and community documents.
-   [x] Add local quality gate hook.
-   [ ] Create Xcode macOS app target.
-   [x] Create Rust workspace.
-   [x] Upgrade local Rust to 1.99.1 (upstream MSRV is 1.95).
-   [x] Pin Rust toolchain in `rust-toolchain.toml` (1.99.1).
-   [x] Pin `whatsapp-rust` to `main` @ `0a6ae10`.
-   [ ] Pin UniFFI version.
-   [ ] Create build scripts.
-   [ ] Add documentation skeleton.

### Epic B --- Protocol proof of concept

-   [x] Inspect upstream README and API docs.
-   [x] Inspect feature flags and storage implementation.
-   [x] Pair a dedicated test account.
-   [ ] Persist session in SQLCipher with a Keychain key.
-   [ ] Verify the durability hook with a crash test.
-   [x] Receive a text message.
-   [x] Send a text message.
-   [ ] Test reconnect.
-   [ ] Test media transfer.
-   [ ] Document limitations.

### Epic C --- Swift/Rust bridge

-   [ ] Define NIMQO DTOs.
-   [ ] Define typed error model.
-   [ ] Expose client lifecycle.
-   [ ] Expose pairing API.
-   [ ] Expose connection state.
-   [ ] Expose message operations.
-   [ ] Expose event subscription.
-   [ ] Verify async/cancellation/lifetime behavior.
-   [ ] Add contract tests.

### Epic D --- Native shell

-   [ ] Build main window.
-   [ ] Build navigation sidebar.
-   [ ] Build chat list placeholder with real model contract.
-   [ ] Build conversation shell.
-   [ ] Add Menu Bar Extra.
-   [ ] Define close/hide/quit behavior.
-   [ ] Add light/dark support.
-   [ ] Add accessibility foundations.

### Epic E --- Core messaging

-   [ ] Implement pairing UX.
-   [ ] Implement session restoration.
-   [ ] Implement event dispatcher.
-   [ ] Implement chat list.
-   [ ] Implement message timeline.
-   [ ] Implement text composer.
-   [ ] Implement send/receive.
-   [ ] Implement unread state and mark as read.
-   [ ] Implement outbox.
-   [ ] Implement contacts, identity mapping, and group metadata.
-   [ ] Handle incoming edits, deletes, reactions, and expiry.
-   [ ] Add unsupported and undecryptable message states.
-   [ ] Add regression tests.

------------------------------------------------------------------------

## 20. Risks and Mitigations

  -----------------------------------------------------------------------
  Risk                    Impact                  Mitigation
  ----------------------- ----------------------- -----------------------
  WhatsApp protocol       Core features stop      Pin upstream, monitor
  changes                 working                 releases, adapter
                                                  layer, regression
                                                  accounts

  Upstream API breaking   Build/behavior          Exact version pin and
  changes                 regression              controlled upgrades

  Account restrictions    User loses access       Clear disclaimer, avoid
                                                  abusive automation, no
                                                  guarantee of safety

  Incomplete feature      Expectations not met    Public feature matrix
  parity                                          and verified status

  Storage encryption      Sensitive local data    Phase 0 spike, fail
  complexity              exposed or lost         closed, tests, external
                                                  review, disclosed risks

  macOS unqualified       Runtime defects on the  Local macOS gate and
  upstream                only target platform    real-account regression

  Keychain loss           Local history lost      Onboarding disclosure,
                                                  re-pair flow, no backdoor

  Legal or platform       Takedown, or Developer  Clear disclaimer, no
  action                  ID revoked              branding use, source
                                                  remains buildable; seek
                                                  legal review

  Signing credential      Stolen signing          Keychain only, never in
  exposure                credentials             repo; review before
                                                  running contributed code

  No hosted CI            Checks skipped or       Versioned pre-push hook,
                          environment-specific    re-run before merge and
                                                  release

  Quality gate blocks     Slow delivery or        Testable architecture;
  delivery                gaming of checks        justified suppressions
                                                  only

  -----------------------------------------------------------------------

------------------------------------------------------------------------

## 21. Product Policies and User Communication

NIMQO must clearly disclose:

-   It is an unofficial third-party application.
-   It is not affiliated with, endorsed by, or sponsored by WhatsApp or
    Meta.
-   It uses an independently maintained implementation of the WhatsApp
    Web protocol.
-   Compatibility may change when the upstream service changes.
-   Account restrictions are possible under the service provider's
    policies.
-   Local data is stored on the user's Mac according to the documented
    storage policy.
-   Any diagnostic data collection must be explicitly described and
    minimized.
-   Local data is encrypted, and losing the Keychain item means losing
    local history.
-   The update check is a network request separate from WhatsApp.

Do not imply that NIMQO can guarantee the same security certification,
reliability, or support level as the official WhatsApp applications. The
WhatsApp protocol may provide end-to-end encryption, but NIMQO's local
storage, UI, operating environment, and implementation still need their
own security review.

------------------------------------------------------------------------

## 22. Definition of MVP

The MVP is not every feature in the upstream protocol. It is a
dependable native messaging client with a complete core experience.

### MVP must include

-   First-run onboarding and unofficial-client disclosure.
-   QR pairing.
-   Persistent session.
-   Connection state and reconnect.
-   Chat list and conversation timeline.
-   Send and receive text messages in direct and group chats.
-   Contact names, avatars, group metadata, and LID/phone identity.
-   Message status where the protocol provides it.
-   Durable inbound storage and a durable outbox.
-   Incoming edits, deletes, reactions, and disappearing-message expiry.
-   Placeholders for unsupported and undecryptable messages.
-   Basic history sync.
-   Unread counts and mark as read.
-   Image and document send/receive, if validated.
-   Native notifications.
-   Menu Bar Extra.
-   Main-window hide/restore behavior.
-   Basic settings.
-   Logout and local reset with key destruction.
-   Encrypted databases, media, and thumbnails.
-   Privacy-safe logging.
-   Tests and signed beta packaging.
-   Local quality gate passing on the release commit.

### MVP should not be blocked by

-   Group video calls.
-   Screen sharing.
-   Plugin system.
-   AI/MCP integration.
-   Multiple accounts.
-   Advanced automation.
-   Cloud backup.
-   Full parity with every official WhatsApp feature.

------------------------------------------------------------------------

## 23. First Development Sprint: Exact Order

The first implementation sprint should follow this order:

1.  Create the repository, documentation skeleton, and local quality
    gate hook. Upgrade Rust to at least 1.95.
2.  Inspect the current upstream `whatsapp-rust` source and examples.
3.  Pin the exact upstream revision and confirm its MIT license.
4.  Create a minimal Rust binary that pairs and exchanges text messages
    **using SQLCipher from its first run**, with a Keychain-held key.
5.  Verify encryption with the Section 11.3 tests, including `otool -L`.
6.  Measure session persistence and reconnect behavior on macOS.
7.  Verify `InboundDurabilityHook` with a crash test.
8.  Create a minimal SwiftUI macOS app targeting macOS 14.
9.  Integrate UniFFI and call one Rust function from Swift.
10. Expose asynchronous connect and connection-state operations.
11. Deliver a QR pairing screen.
12. Complete a real-account pairing and messaging test.
13. Record the first performance and memory baseline.
14. Review the results before adding chat history.

**Do not begin with the Liquid Glass polish.** Establish the protocol,
encryption, lifecycle, bridge, and data model first. Build the final visual system
on top of stable state and API contracts.

------------------------------------------------------------------------

## 24. Baseline Architecture Decisions

  -----------------------------------------------------------------------
  Decision                            Baseline
  ----------------------------------- -----------------------------------
  Product name                        NIMQO

  Platform                            macOS

  UI                                  SwiftUI

  Native integration                  AppKit

  Core language                       Rust

  Protocol library                    `whatsapp-rust`

  Swift/Rust bridge                   UniFFI

  Initial process model               Embedded Rust core

  Async model                         Tokio integration validated in POC

  Local app data                      SQLCipher, schema owned by NIMQO;
                                      source of truth for messages

  Protocol/session storage            Upstream SQLite store on SQLCipher
                                      via `with_connection_init`

  Encryption                          Mandatory from first run; fails
                                      closed; includes media

  Secret storage                      macOS Keychain, device-only

  Search                              FTS5 inside SQLCipher

  Inbound durability                  `InboundDurabilityHook`, keyed by
                                      `(chat, sender, id)`

  Visual language                     Native macOS; Liquid Glass on 26+,
                                      system materials on 14 and 15

  Menu bar                            SwiftUI MenuBarExtra

  Minimum OS                          macOS 14 Sonoma

  Initial distribution                Public GitHub source; signed and
                                      notarized DMG on GitHub Releases

  License                             MIT

  Repository                          github.com/wprimadi/nimqo (public)

  Quality                             Mandatory local gate (pre-push)

  First release scope                 Core messaging MVP

  Multiple accounts                   Deferred

  AI/MCP                              Deferred
  -----------------------------------------------------------------------

These are baseline decisions, not permission to ignore proof-of-concept
findings. Any change should be recorded in an ADR.

------------------------------------------------------------------------

## 25. Reference Links

### Core project

-   [`whatsapp-rust` GitHub](https://github.com/oxidezap/whatsapp-rust)
-   [`whatsapp-rust`
    releases](https://github.com/oxidezap/whatsapp-rust/releases)
-   [`whatsapp-rust` documentation](https://whatsapp-rust.jlucaso.com/)
-   [`oxidezap/client` reference
    implementation](https://github.com/oxidezap/client)

### Apple development

-   [SwiftUI
    documentation](https://developer.apple.com/documentation/swiftui)
-   [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)
-   [Apple Developer
    Documentation](https://developer.apple.com/documentation/)
-   [Apple Human Interface
    Guidelines](https://developer.apple.com/design/human-interface-guidelines/)

### Rust and interoperability

-   [UniFFI documentation](https://mozilla.github.io/uniffi-rs/)
-   [UniFFI async
    support](https://mozilla.github.io/uniffi-rs/latest/futures.html)
-   [Rust documentation](https://doc.rust-lang.org/)
-   [Tokio documentation](https://tokio.rs/)

### Security and release

-   [`whatsapp-rust` support qualification](https://github.com/oxidezap/whatsapp-rust/blob/main/agent_docs/support.md)
-   [SQLCipher documentation](https://www.zetetic.net/sqlcipher/documentation/)
-   [RustSec Advisory Database](https://rustsec.org/)
-   [cargo-audit](https://github.com/rustsec/rustsec/tree/main/cargo-audit)
-   [cargo-deny](https://github.com/EmbarkStudios/cargo-deny)
-   [Apple
    notarization](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution)

------------------------------------------------------------------------

## Closing Principle

**NIMQO should be engineered as a native macOS product, not as a
protocol demo with a beautiful skin.**

The protocol layer, application lifecycle, storage, security, and event
model must be dependable before the product expands into advanced
features. SwiftUI should deliver the native experience; Rust should
provide a focused, testable, and efficient core.

The first milestone is not a polished screenshot. It is a repeatable
proof that NIMQO can pair, persist its session **in encrypted storage**,
reconnect, send and receive messages, and remain responsive through the
Swift/Rust boundary, with the local quality gate passing.
