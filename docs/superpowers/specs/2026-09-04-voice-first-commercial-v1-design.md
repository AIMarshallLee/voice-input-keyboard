# VoType Voice-First Commercial V1 Design

**Status:** Proposed and approved in chat; pending written-spec review

**Date:** 2026-09-04

**Product:** VoType / 声入

**Baseline:** `main` at `ba3ca0e317948da5179bcf22dc2fa082da539a1a`

## 1. Problem

VoType 1.0 (146) is a signed TestFlight candidate, not a finished product.
The current app has useful pieces—session-scoped IPC, Apple Speech, visible PiP
standby, a local Pinyin lexicon, text processing and release gates—but it has
not passed the real-device matrix required for a commercial keyboard.

The largest product gaps are:

1. Foreground dictation and PiP dictation use separate recording
   implementations, so lifecycle, interruption and terminal-state behavior can
   drift.
2. iOS does not guarantee that a custom keyboard can open its containing app.
   PiP can enable in-place dictation, but PiP availability and background
   survival remain system-controlled.
3. The local Chinese keyboard is a fallback prototype. It is less discoverable
   and has materially less context handling, layout adaptation and candidate
   quality than a mature Chinese input method.
4. Simulator tests cannot establish microphone, PiP, app switching, extension
   eviction, audio-route, memory or third-party insertion reliability.

“Reach the Typeless and WeChat Input Method standard” therefore means matching
their core jobs with measurable reliability. It does not mean cloning every
feature, brand element, cloud model or marketing claim.

## 2. Product goal

Deliver a simple, voice-first iOS keyboard that reliably completes three jobs:

1. With an active, accepted PiP path, start and stop Chinese or English
   dictation in the original text field; without it, queue the request and
   provide immediate, truthful manual-open recovery that holds the result for
   explicit insertion after the user returns to the intended field.
2. Provide the defined commercial baseline for local Chinese Pinyin/English
   typing when voice is unavailable or inappropriate, including when Full
   Access is disabled.
3. Recover visibly from every expected iOS restriction or interruption without
   indefinite loading, stale insertion, duplicate insertion or hidden recording.

The commercial V1 release candidate is complete only when the implementation,
automated gates, signed TestFlight build and defined physical-device matrix all
pass. It may be called App Store shipped only after Apple accepts the selected
PiP or non-PiP configuration; App Review is a separate external decision.

## 3. Public benchmark interpretation

The benchmark is based on publicly documented core behavior:

- Typeless: one-tap dictation into the original field, PiP-backed in-place
  dictation, swipe access to typing and speech-driven editing.
- WeChat Input Method: mature Chinese Pinyin, candidates, voice entry and
  ordinary keyboard completeness.
- Apple: custom keyboards cannot directly use the microphone; open access,
  shared-container behavior, extension memory and lifecycle rules still apply.

VoType must not promise that PiP always starts, that the host always opens from
the keyboard, that Apple Speech is always offline, or that every language has
equal quality.

## 4. Scope decomposition

This program is delivered in the dependency order A -> B -> C -> D. Each slice
must be independently reviewable and revertible, and the product must remain
usable and testable after each merge. A later slice may consume an earlier
slice's public contract but may not silently expand it.

After this design is approved, the first implementation plan covers Slice A
only. Each later slice receives its own reviewed plan after the preceding exit
criteria have fresh evidence.

### Slice A — Reliable session engine

Create one shared dictation lifecycle used by both foreground and PiP entry
points. Remove duplicated permission, audio, recognition, timeout,
interruption, cancellation and terminal-write logic.

Scope is limited to the `VoiceInputApp` lifecycle engine and adapters, shared
session/IPC contracts, and their tests. It does not redesign the keyboard,
Pinyin ranking or text processing.

### Slice B — Simple voice surface and complete typing fallback

Keep the default surface voice-first while making the typing fallback explicit,
discoverable and complete. Improve Chinese composition, candidate navigation,
context scoring and field-specific layouts without turning the voice surface
into a settings dashboard.

This slice depends on Slice A's session contract. Scope is limited to the
keyboard extension's Voice/Type surfaces, local Pinyin engine and their tests;
it does not change audio capture or recognition ownership.

### Slice C — Voice quality and speak-to-edit

Harden filler removal, self-correction, punctuation, list formatting, personal
dictionary behavior and selected-text editing. Destructive or context-sensitive
edits must fail closed when the editor context changes.

This slice depends on Slice A's events and Slice B's editor-context handling.
Scope is limited to text processing, personal-dictionary behavior,
capability-gated selected-text actions and their corpora/tests. It does not
redesign the keyboard or add a new speech backend.

### Slice D — Diagnostics, device qualification and release

Add privacy-safe diagnostics, execute the physical-device matrix, fix failures,
then publish a new internal TestFlight candidate. Store metadata and App Review
remain outside this slice until the user explicitly authorizes them.

Fixes in this slice are limited to defects that prevent an earlier slice's
accepted behavior from passing the defined gates. New end-user features are out
of scope and return to design review.

## 5. Architecture

### 5.1 Shared dictation lifecycle

Introduce a single actor-isolated `DictationSessionEngine` in `VoiceInputApp`.
The actor is the sole owner of mutable session-control state and owns:

- permission resolution;
- `AVAudioSession` activation and route changes;
- `AVAudioEngine` lifecycle;
- `SFSpeechRecognizer` and request/task lifecycle;
- partial transcript emission;
- silence, start and finalization deadlines;
- interruption and media-services reset handling;
- cancellation and exactly-one terminal event.

The engine consumes an immutable `DictationSessionRequest` containing one
canonical `SessionToken`, language, whisper flag and text-processing snapshot.
`SessionToken` contains only a random request UUID and is the sole identity
serialized across the app/extension boundary in every request, result and
receipt. The actor allocates a monotonically increasing, process-local
`EngineGeneration` to reject callbacks from superseded in-process work; that
generation is never used as cross-process identity or persisted. Events carry
the token and an actor-assigned sequence number:

```swift
struct DictationSessionEventEnvelope: Equatable {
    let token: SessionToken
    let sequence: UInt64
    let event: DictationSessionEvent
}

enum DictationSessionEvent: Equatable {
    case authorizing
    case preparing
    case listening(partial: String)
    case processing
    case completed(EditPlan)
    case failed(DictationFailure)
    case cancelled
}

struct EditPlan: Equatable {
    let intent: EditIntent
    let operation: EditOperation
    let text: String
    let expectedContextFingerprint: String?
    let requiresConfirmation: Bool
}

enum EditIntent: Equatable {
    case dictate
    case append
    case rewrite
    case translate(targetLanguage: String)
    case delete
}

enum EditOperation: Equatable {
    case insertAtCursor
    case replaceSelection
    case deleteSelection
    case previewOnly
}
```

Its state graph is one-way for a generation:

```text
idle
  -> authorizing
  -> preparing | failed | cancelled
  -> listening | failed | cancelled
  -> processing | failed | cancelled
  -> completed | failed | cancelled
  -> idle
```

Every Apple-framework control callback and scheduler deadline captures its
`SessionToken` and process-local `EngineGeneration`, then immediately hops into
the engine actor before inspecting or mutating session state. The actor emits
ordered events through one per-session `AsyncStream`; presentation adapters
consume that stream on `@MainActor`.

Audio buffers are the exception: the capture adapter appends them on one
dedicated serial data path and never creates a task per buffer. Engine stop or
cancel performs a barrier on that path before releasing the recognition
request. Partial transcripts are coalesced into a bounded latest-value stream;
control and terminal events are ordered and never dropped.

No callback from an older generation may mutate the current generation. A
terminal event is accepted once. `cancel` is idempotent, and no command creates
a second result.
The only terminal commit point is an actor-isolated `finish` operation. It
closes recognition/audio resources, freezes the terminal envelope, asks the
serialized output port to atomically replace the session result, then closes
the event stream. `completed` is emitted only after that write succeeds. If the
write fails, the in-memory UI receives one `failed(.outputPersistence)` event;
the keyboard receives no fabricated result or receipt and its bounded timeout
offers retry/manual recovery. Re-entrant or late finish attempts are ignored
and recorded only as diagnostic event codes.

Command semantics are fixed: `stop` while listening enters processing; `stop`
while authorizing/preparing cancels; `stop` during processing is a no-op;
`cancel` from any nonterminal state discards partial text and ends cancelled.
An audio interruption ends the session once with a retryable failure—V1 has no
implicit pause/resume state.

`DictationViewModel` becomes a presentation adapter for cold/foreground entry.
`BackgroundDictationManager` becomes an IPC/PiP adapter for hot entry. Neither
adapter directly constructs an audio engine or speech task.

### 5.2 Dependency seams

The engine receives narrow protocols for speech recognition, audio capture,
audio-session control, scheduling and output. Production adapters wrap Apple
frameworks; tests use deterministic fakes. Test fakes stay in the test target.

This permits state-transition and interruption tests without pretending that a
simulator proves microphone or PiP behavior.

### 5.3 Session and IPC contract

Existing App Group files and Darwin notifications remain the transport. The
contract is tightened as follows:

- UUID, creation time and editor-context snapshot identify a request.
- Only the active generation can publish live or terminal state.
- Live phases cannot regress.
- A consumed, cancelled or expired session rejects late writes.
- The keyboard inserts a terminal result at most once and only when the editor
  context still satisfies the recovery policy.
- Terminal result and consumption receipt use the same random request UUID.
  Atomic file replacement publishes each envelope; the serialized session
  ledger is the single authority that rejects a duplicate result or receipt.
- The new encoder writes `EditPlan`. A legacy `deleteSelected == false` payload
  decodes as `insertAtCursor`; a legacy destructive payload decodes as
  `previewOnly` unless the exact current selection can be revalidated. Old
  destructive payloads never bypass confirmation.
- Raw audio is never persisted.

### 5.4 Launch and PiP contract

PiP is an optional hot path, not an availability or App Review promise.

- Starting PiP requires device support and current
  `isPictureInPicturePossible`.
- PiP start must reach active state or a retryable failure within 4 seconds.
- Readiness exists only while PiP is active and not already recording.
- A hot keyboard request must produce a `preparing`/`listening` acknowledgement
  within 1.2 seconds or move to manual-open recovery.
- A distribution build, including TestFlight and App Store, never uses
  responder-chain `openURL` or
  `extensionContext.open` to launch VoType from its keyboard. Without valid PiP
  readiness, the keyboard stores the pending session and immediately tells the
  user to open VoType manually. The host starts only after a real foreground
  launch and matching acknowledgement. Its result is always held until the user
  returns to a field and explicitly chooses insert, copy or discard.
- If the containing app does not acknowledge within 3 seconds after that launch,
  the keyboard keeps retry available and shows an explicit recovery error.
- No waiting state is unbounded.
- The PiP scene must remain visibly related to an active VoType voice session
  and expose truthful state and stop/cancel controls. VoType must not use silent
  media or a misleading PiP scene solely to obtain background execution. If
  App Review or a supported OS rejects the PiP path, foreground/manual recovery
  remains the supported fallback.

Both microphone and speech permissions are requested and resolved while the
containing app is foregrounded, before PiP standby may become ready. A hot
background path only reads existing authorization state and never presents
permission UI. Revocation during standby fails the matching session once,
disables readiness and directs the user to foreground recovery.

PiP has a static release switch. A non-PiP build removes its controls and any
background-audio declaration not otherwise required. Flipping the switch
creates a new signed build and invalidates earlier PiP, permission, lifecycle
and background-mode evidence, so those applicable device gates run again. The
no-PiP configuration must still pass the baseline manual-open voice flow,
typing, timeout and recovery gates. App Review notes describe the visible user
function honestly; rejection of PiP blocks that configuration from being
called App Store ready.

### 5.5 Setup-status evidence

The containing app must not infer keyboard installation or Full Access from a
Settings deep-link. When the extension appears with `hasFullAccess == true`, it
can publish a versioned positive heartbeat containing its app version and
verification time. With Full Access disabled the extension cannot rely on App
Group writes, so heartbeat absence is never interpreted as proof that the
keyboard is missing or access is disabled.

The app shows “已验证” only for a matching-version positive heartbeat no older
than 24 hours, with the verification time visible. Missing, expired or
different-version evidence shows “待验证：打开任意输入框并切换一次 VoType”，
not “未安装”, a permanent spinner or a false checkmark. “需要操作” is reserved
for a denial directly reported by a system authorization API. Speech and
microphone permission continue to use those APIs. The keyboard itself reads
`hasFullAccess` directly and can show an immediate local warning when false,
without claiming that the containing app received that state.

### 5.6 Privacy-safe diagnostics

Add an on-device bounded diagnostic ring containing only timestamps, event
codes, elapsed durations, OS/device family, speech availability, PiP
possible/active flags and audio-route category. It must not contain raw audio,
transcripts, selected text, keyboard content, personal dictionary entries or
credentials.

The production ring stores at most 200 events and removes events older than
seven days. It never stores or derives the target app identity. The support
screen previews the complete report before a separate, user-initiated share
action. Diagnostics are never uploaded automatically and are deleted by the
existing local-data reset; the reset flow has a verification test.

The signed-device qualification table is a separate test artifact maintained by
the team. It may name the target app, build and device/OS, but contains no user
content and is never copied into the production ring or its export.

If the user deliberately shares a report with support, it becomes support data,
not product telemetry. The privacy/support documents identify the actual
channel, retain the report for no more than 30 days after the support case is
closed, provide an earlier deletion-request route and prohibit model training or
unrelated analytics use.

## 6. Keyboard experience

### 6.1 Two explicit surfaces

The extension has two first-class surfaces:

1. **Voice:** large microphone, compact live transcript/status, stop/cancel,
   language indicator and one obvious typing button.
2. **Type:** Chinese Pinyin or English QWERTY with candidate/composition row,
   numbers, symbols, space, return, delete and next-keyboard key.

Horizontal swipe remains supported, but it is never the only discovery method.
First install defaults to Voice. The last explicit surface and Chinese/English
mode are stored locally. Full Access disabled leaves Type fully usable and
replaces voice actions with one concise recovery control.

Advanced settings stay in the containing app. Translate, whisper and language
controls may appear as compact state indicators, not as a dense toolbar.

### 6.2 Pinyin baseline

Commercial V1 includes:

- continuous full-Pinyin composition;
- horizontally scrollable candidates rather than a fixed visible limit;
- space to commit the first candidate;
- candidate tap with bounded local learning;
- composition-aware backspace and accelerated hold-to-delete;
- Chinese punctuation mapping;
- basic fuzzy-Pinyin aliases behind an explicit setting;
- context scoring using only bounded local preceding-text context;
- email, URL, number and default field layouts;
- correct next-keyboard behavior; secure, `phonePad` and `namePhonePad` fields
  are explicit system-takeover cases, not claimed VoType layouts.

The engine does not add cloud candidate lookup, clipboard history, handwriting,
emoji search, themes or social content in this program. Those features do not
raise the reliability of the core voice job.

### 6.3 Text quality and speak-to-edit

The text processor keeps user facts and proper nouns unchanged unless a
personal-dictionary rule or explicit selected-text instruction requires a
change. It supports:

- filler-word removal with boundary-aware rules;
- spoken self-correction that retains only the final intended phrase;
- language-specific punctuation;
- numbered and bulleted list formatting;
- selected-text replace, append, rewrite, translate and delete intents;
- a safe failure when selection/context evidence changed before insertion.

Selected-text replacement or deletion is enabled only when the host exposes a
non-empty `textDocumentProxy.selectedText` and it exactly matches the snapshot
captured for the request. VoType cannot obtain a host selection range or claim
uniform selected-text support across third-party apps.

Automatic insertion is limited to a continuously active hot PiP session. At
request creation the keyboard records an in-memory extension-instance nonce,
an editor epoch and a non-empty bounded editor fingerprint. Any external
`textWillChange`/`textDidChange` or
`selectionWillChange`/`selectionDidChange` callback advances the epoch;
callbacks caused by VoType's own final commit carry one scoped suppression tag
covering both text and selection notifications. Auto-insert requires the same
live instance, unchanged epoch and matching fingerprint. An empty field, an
extension recreation, a cursor/selection move, a field switch even when its
text is identical, or any manual-open route therefore always produces a held
result. The fingerprint can reject changed context but, by itself, never proves
field identity.

If selection is unavailable, empty or changed, destructive actions are not
performed. The result is held as a preview with explicit “insert at cursor”,
“copy”, and “discard” choices; instructions explain that manual replacement may
be required. Low-confidence destructive edits follow the same preview path.
No delete/replace mutation or consumption receipt is produced until a required
confirmation succeeds against the current selection/context fingerprint.

## 7. User-visible failure behavior

Every failure maps to one short action:

| Condition | User-visible result |
| --- | --- |
| Full Access disabled | Typing remains available; voice shows “开启完全访问” |
| Speech permission denied | “在系统设置中允许语音识别” |
| Microphone denied | “在系统设置中允许麦克风” |
| PiP unavailable | Retry remains enabled; manual-open recovery is offered |
| Host did not open | “请从主屏幕打开 VoType，返回后继续” |
| Apple Speech unavailable/offline | Accurate availability message; no offline claim |
| Audio interruption | Current session fails visibly once; next session can start |
| Editor context changed | Result is held for explicit insert/discard confirmation |
| Processing timeout | Session terminates once with retry; no indefinite spinner |

## 8. Acceptance gates

### 8.1 Automated correctness

- All state-machine transitions, illegal transitions, cancellation races,
  superseding sessions and late callbacks have table-driven XCTest coverage.
- Concurrent recognition-final, timeout, interruption, cancel and superseding
  callbacks are deliberately released from different executors in tests; every
  schedule produces one ordered event stream and at most one terminal commit.
- Editor-epoch tests cover all four text/selection callbacks: a tagged VoType
  commit does not invalidate itself, the suppression is scoped to that commit,
  and the next external cursor, selection or text change does invalidate it.
- Foreground and PiP adapters pass the same lifecycle contract suite.
- Fifty sequential session round trips leave no active payload or cross-session
  effect from a previous session. Bounded session-scoped cancellation/receipt
  tombstones may remain for the existing 24-hour replay-protection period, must
  not affect later tokens and must be removed by deterministic cleanup tests.
- Each simulated request produces zero or one terminal result and zero or one
  insertion.
- Onboarding status, Voice/Type discovery, timeout recovery and held-result
  confirmation have UI tests.

### 8.2 Pinyin quality and performance

- A versioned, rights-cleared manifest contains at least 200 representative
  Simplified Chinese phrases, their normalized Pinyin input, gold candidates
  and category labels. The checked-in normalizer defines case, tone, spacing,
  apostrophe and punctuation handling. Before adaptive learning, the corpus
  achieves at least 80% Top-1 and 95% Top-5.
- Learned selection becomes Top-1 for the same Pinyin without inventing a
  candidate and survives extension recreation.
- CI is a deterministic ranking/regression gate and uses a 500 ms per-query
  hang guard; hosted-runner timing is recorded but is not product-performance
  evidence.
- On the fixed reference device/OS/build declared in the benchmark manifest,
  after five warm-up passes and twenty measured passes per phrase, nearest-rank
  warm query p95 is under 40 ms and worst case under 100 ms. Keyboard cold
  presentation p95 across twenty launches is under 1 second and extension peak
  memory is under 45 MB.

### 8.3 Voice experience

- With active PiP readiness, tap-to-listening p95 is at most 1.5 seconds.
- PiP start never stays pending beyond 4 seconds.
- Without PiP readiness, a microphone tap shows manual-open recovery within
  1.2 seconds; after the user foregrounds VoType, the matching queued request
  starts once and its result is held until the user explicitly inserts, copies
  or discards it after returning to a text field.
- After stop, non-LLM final text appears or an explicit error is shown within
  5 seconds under a working Apple Speech service.
- A checked-in manifest defines fifty rights-cleared Mandarin prompts covering
  numbers, names, punctuation, corrections and short/long phrases, plus the
  normalizer and Levenshtein-based CER calculation. At least three speakers use
  the fixed reference device at the documented 30-50 cm distance. The evidence
  records build, device/OS, locale, Apple Speech availability/on-device state,
  microphone route and measured ambient-noise range. CER is reported separately
  for quiet and ordinary-room conditions; release targets are at most 8% and
  15% respectively.
- Network-backed and on-device Apple Speech runs are reported separately.
  On-device/offline results are gated only when
  `supportsOnDeviceRecognition` is true on the declared reference device; when
  false, the report says unsupported and VoType makes no offline claim.
- Filler removal, self-correction and formatting must not change benchmark
  facts, numbers or protected proper nouns.

### 8.4 Physical-device matrix

The exact signed candidate is tested on the oldest supported iOS/iPhone class,
the current iOS/iPhone class, iOS 26 and one iPad. At minimum, run:

- first grant, denial, Settings re-grant, Full Access revocation and permission
  revocation while PiP standby is active;
- PiP start/stop, system PiP close and host eviction;
- WeChat, Notes, Safari and Mail insertion;
- for each of WeChat, Notes, Safari and Mail, selected-text visibility plus the
  expected replace, append, rewrite, translate and delete outcome; unsupported
  combinations must take the preview/copy/manual-replace path;
- foreground/manual recovery and extension recreation;
- hot sessions in an empty field, two different fields with identical context,
  cursor movement, selection movement between repeated identical text, manual
  return to a different app/field and extension eviction; ambiguous identity
  must hold the result and never auto-insert;
- Mandarin, English and one additional supported language;
- Chinese Pinyin, English, email, URL and number fields; secure, `phonePad` and
  `namePhonePad` cases verify that iOS correctly replaces VoType with the system
  keyboard;
- phone/Siri interruption, Bluetooth route change and headset removal;
- Wi-Fi, cellular, weak network and offline behavior;
- VoiceOver focus/order and Dynamic Type in the containing app and the keyboard
  Voice/Type surfaces, candidate row and edit-confirmation view;
- 50 sequential voice starts/stops and 15 minutes of mixed voice/typing use.

Failures are recorded against build, device, OS, target app and diagnostic
event codes in the separate qualification table, never in the production
diagnostic ring. Simulator results cannot close a physical-device gate.

## 9. Release slices and stop conditions

### Slice A exit

One engine serves both entry paths; lifecycle contract, race and timeout tests
pass; the programmatic keyboard-to-host launch path is absent from every
distribution configuration; unsigned Release device build and archive pass. No TestFlight
upload is required merely to close Slice A.

### Slice B exit

Two-surface keyboard, field layouts and Pinyin corpus gates pass in CI; typing
works with Full Access disabled; reference-device startup/memory evidence is
captured.

### Slice C exit

Voice-quality corpus and selected-text safety gates pass; no benchmark fact or
proper noun is silently changed. The four target apps either pass each declared
edit intent or demonstrate the specified non-destructive fallback.

### Slice D exit

All automated gates and the full signed physical-device matrix pass. Only then
may a new internal TestFlight build be called a release candidate. App Store
metadata upload and App Review require separate explicit user authorization.

## 10. Alternatives considered

### Full WeChat feature parity in one release

Rejected. Clipboard history, handwriting, emoji, themes and social/AI features
would expand scope without fixing the primary voice and reliability gaps.

### New developer-operated cloud speech/LLM backend

Deferred. It could improve accuracy or language coverage, but introduces
accounts, cost, network dependence, data retention, security and App Store
privacy obligations. Commercial V1 continues to use Apple Speech and optional
on-device Foundation Models.

### Keep both recording implementations and align them with tests

Rejected. Contract tests would reduce drift but leave duplicated ownership of
audio-session and callback races—the highest-risk part of the app.

## 11. Rollback and compatibility

- App Group filenames and payload decoding remain backward-compatible while a
  build is in TestFlight; new fields use defaults.
- A release-slice branch can be reverted without deleting user dictionaries or
  Pinyin learning data.
- If the unified engine regresses after device testing, roll back the adapter
  integration while retaining new diagnostics and test fixtures.
- Existing build 146 remains the comparison build until a later signed build
  completes processing and physical-device validation.

## 12. Documentation impact

Each slice updates architecture, flows, tests, first-run/recovery, privacy-data,
CHANGELOG and the release checklist only where behavior actually changed.
Versioned TestFlight evidence is added only after Apple processing and Internal
Testers distribution are confirmed. Claims of parity or superiority remain
prohibited until benchmark and device evidence supports them.

## 13. Public references

- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Apple: Creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard)
- [Apple: Custom Keyboard Programming Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html)
- [Apple: AVPictureInPictureController](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller)
- [Apple: supportsOnDeviceRecognition](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition)
- [Typeless: Dictate](https://www.typeless.com/help/quickstart/dictate)
- [Typeless: Picture in Picture](https://www.typeless.com/help/release-notes/ios/picture-in-picture)
- [Typeless: Speak to edit](https://www.typeless.com/help/release-notes/ios/speak-to-edit)
- [Typeless: Swipe to type](https://www.typeless.com/help/release-notes/ios/swipe-to-type)
- [WeChat Input Method on the App Store](https://apps.apple.com/cn/app/%E5%BE%AE%E4%BF%A1%E8%BE%93%E5%85%A5%E6%B3%95/id1618175312)
