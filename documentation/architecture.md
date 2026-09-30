# VoType 1.0 architecture

## Product and assumptions

VoType is an iOS/iPadOS custom keyboard plus containing app. The keyboard
collects no audio itself: it creates a session, the containing app records and
uses Apple Speech, and the keyboard inserts only the matching result.

There is no VoType account system, backend, database, advertising SDK, or
developer-operated speech service. A UUID is a correlation identifier, not an
authentication credential. The supported baseline is iOS/iPadOS 16; optional
Foundation Models processing requires a supported iOS 26+ device.

## Components

| Component | Technology | Responsibility |
| --- | --- | --- |
| `VoiceInputApp` | SwiftUI, Speech, AVFoundation, AVKit | Onboarding, permissions, PiP standby, recording, recognition, processing, settings |
| `KeyboardExtension` | UIKit custom keyboard | Session creation, status display, result insertion, Chinese Pinyin and English typing |
| `Shared` | Swift/Foundation | App Group IPC, session recovery, language/settings, text processing and local statistics |
| App Group | `group.com.daseanle.votype.container` | Local preferences and short-lived session files shared by the two processes |
| Apple Speech | `SFSpeechRecognizer` | On-device recognition when supported; Apple may process online otherwise |
| Foundation Models | `LanguageModelSession` | Optional on-device polish, formatting and translation; no tool calls |
| GitHub Actions | XcodeGen, Xcode, Fastlane | Tests, device build, signing checks, IPA artifact and manual TestFlight upload |

`project.yml` is the authoritative Xcode project definition. Generated Xcode
projects and generated Info.plists are not source-of-truth files.

## Session and trust-boundary path

1. The keyboard creates a UUID and writes session settings into the App Group.
2. A Darwin notification carries only a fixed name or hashed session token.
3. A running PiP standby receives the request in place. Otherwise the keyboard
   saves the request and presents manual-open recovery; it does not attempt an
   unsupported keyboard-side launch of the containing app.
4. The app activates the microphone only for the requested session and streams
   audio to Apple Speech. No audio file is created by VoType.
5. Partial state and the first terminal result are atomically written to
   session-scoped protected files.
6. Automatic insertion is limited to an unconfirmed cursor insert in the same
   in-place extension instance, with no live selection and matching non-empty
   editor context. Results from a recreated extension or manual recovery stay
   held for explicit user action.

Trust boundaries are: keyboard process to App Group; app to the iOS microphone
and Speech service; app to the on-device Foundation Model; GitHub Actions to
App Store Connect. The session UUID prevents accidental cross-session use but
does not authorize a remote principal because there is no remote API.

## Slice A session engine

One actor owns permission, audio, Speech, deadlines and terminal state. A single
synchronous buffer gate, closed before terminal work, is the only PCM append
path. Foreground and PiP are adapters over that same engine, so neither creates
a competing recorder or recognizer.

Foreground discovery does not require a deep link: it peeks at pending settings,
then atomically claims the exact request within three seconds before calling
`engine.start`. The returned stream must begin with the matching `.authorizing`
event; a claim miss leaves the request recoverable and exposes failure. The
injected, cancellable 1.2-second hot acknowledgement timer falls back to manual
recovery. On timeout, a fresh manual UUID is first staged where it is not
discoverable, then the old UUID is durably cancelled with the replacement
identity, and only then is the replacement promoted. The active hot adapter also
reconciles persisted cancellation during admission and while running; its
0.5-second check is best-effort only while the process runs, not an iOS
suspension deadline.

Cancellation evidence is retained when unreadable. A source record may retain
only a replacement UUID and timestamp as a handoff identity; unresolved linked
records outlive ordinary cancellation eligibility until a valid replacement
cancellation or terminal receipt exists. A result-only payload cannot settle
that link. Fresh text remains held-recoverable, and ordinary expired-text cleanup
does not erase the linked identity. Automatic insertion is limited to an
unconfirmed cursor insert for a matching in-place session in the same extension
instance, with no selection and non-empty matching context evidence. Manual or
recreated results remain held. An explicit plain insert/preview checks the held
token, no live selection, non-empty text and that the consumed payload equals the
preview; it can insert into the current field chosen by the user. Confirmed
replace/delete additionally require matching original context and fingerprint
plus a live selection. Copy compares its consumed payload with the frozen
preview; discard validates that the held token still peeks the frozen preview
before consuming that token's result. Neither requires editor-context matching.
Legacy destructive payloads fail closed to preview, and an output-persistence
failure remains an in-memory error rather than a fabricated completed result.

Signed physical-device microphone, Apple Speech, PiP lifecycle, extension eviction, and third-party insertion remain EXTERNAL / NOT_RUN for Slice A.

## Persistence

Short-lived text and state use protected App Group files. Preferences, personal
dictionary entries, bounded Pinyin selection counts and aggregate usage counts
use App Group `UserDefaults`. Exact retention and deletion controls are in
[`privacy-data.md`](privacy-data.md).

## Conditional surfaces

- No transactional email; no `emails.md`.
- No scheduled server work or cron trigger; no `cron.md`.
- No public application routes or SEO surface; no `seo.md`.
- GitHub release automation and the user-triggered on-device model workflow are
  documented in [`automation.md`](automation.md).

## Known risks and assumptions

- iOS does not guarantee that a keyboard extension can open its containing app.
  Slice A does not use that unsupported launch route; it saves recoverable work
  and exposes a timed manual-recovery state instead.
- PiP standby in `PiPStandbyManager.swift` is user initiated and shows real
  standby/recording/processing state, but App Review acceptance and real-device
  lifecycle behavior remain explicit external gates.
- Full Access is required for the keyboard/App Group path. Revoking it must fail
  closed for voice IPC while local typing remains available.
- Apple Speech availability, online processing, duration and locale support are
  controlled by Apple and the device.
- Release logs currently contain Swift actor-isolation warnings in
  `BackgroundDictationManager.swift` and `DictationView.swift`, plus a deprecated
  UIButton inset warning. They are non-blocking under Swift 5.9 but are a Swift
  6 migration risk.
- CI cannot prove microphone indicators, energy use, memory ceiling, app-switch
  behavior, audio interruptions, or insertion into third-party apps. These are
  final-device gates.
- Files currently under `fastlane/screenshots/` are historical placeholders and
  are not approved submission assets.
- CI #183 is automated evidence for source
  `b3be44b88cba83a5768af199ed30f2eec85fdaa6`, not signed-device, TestFlight or
  App Review acceptance.

## Related documents

- [`flows.md`](flows.md) — permission and side-effect journeys
- [`permissions.md`](permissions.md) — static access matrix
- [`variables.md`](variables.md) — configuration and secret handling
- [`tests.md`](tests.md) — existing coverage, proposals and gaps
- [`automation.md`](automation.md) — CI/App Store and model automation
- [`first-run-and-recovery.md`](first-run-and-recovery.md) — user onboarding and recovery
- [`privacy-data.md`](privacy-data.md) — data flow, retention and deletion
- [`release-runbook.md`](release-runbook.md) — signing, archive, rollback and submission
- [`app-store-submission.md`](app-store-submission.md) — metadata and screenshot checklist
