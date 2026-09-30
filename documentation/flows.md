# Permission and side-effect flows

## First launch and keyboard enablement

| Item | Value |
| --- | --- |
| Actor | Device owner |
| Precondition | VoType installed |
| Success | Keyboard enabled, Full Access enabled, microphone and Speech authorized |
| Deny case | Voice controls show a permission/recovery action; local Pinyin/English typing remains usable |

1. The app opens iOS Keyboard Settings; iOS, not VoType, grants keyboard and
   Full Access permission.
2. The app calls the Apple Speech and microphone permission APIs only after a
   user action.
3. iOS returns the authorization state. VoType stores no authorization token.
4. The user explicitly starts PiP standby. This creates visible system UI and
   publishes short-lived readiness; it does not activate the microphone.

Trust crossings: app to iOS Settings and privacy APIs. Side effects: system
permission state and, after an explicit action, an active PiP window.

## In-place voice session

| Item | Value |
| --- | --- |
| Actor | User in a third-party text field |
| Precondition | Fresh PiP `standby`, Full Access, microphone/Speech permission |
| Success | Matching processed text inserted without an App switch |
| Deny case | Stale/not-standby readiness routes to cold launch; missing permission becomes an error, not fake listening |

1. The keyboard verifies readiness is fresh and exactly `standby`.
2. It writes language, feature flags, optional selected text, UUID and timestamp
   into the App Group and posts a Darwin notification.
3. The foreground path may discover the request without a deep link, peeks before
   ownership and atomically claims the exact request within three seconds. Only
   after that claim does it call `engine.start`; the returned event stream must
   start with the matching `.authorizing` event. A claim miss leaves the request
   recoverable with visible failure, and a mismatched first event fails the stream.
4. The one session actor owns permission, audio, Speech, deadlines and the sole
   synchronous PCM buffer gate; the adapter does not own a second recorder.
5. Apple Speech receives audio. Partial transcript state is throttled to about
   five protected App Group writes per second.
6. Text processing uses local rules and, when explicitly enabled and available,
   the on-device Foundation Model. The first terminal state wins.
7. Auto-insertion is allowed only for an unconfirmed cursor insertion from the
   in-place session in the same extension instance, with no selection and
   non-empty matching context evidence. Manual/recreated sessions, empty text and
   destructive or confirmation-required operations stay held. Explicit plain
   insert/preview checks the held token, absence of a live selection, non-empty
   text and that the consumed payload matches the preview; it may insert into the
   user's chosen current field without matching the original context. Confirmed
   replace/delete also require matching context and fingerprint plus a live
   selection. Copy checks the consumed payload against the frozen preview;
   discard validates that the held token still peeks the frozen preview before
   consuming that token's result. Neither requires editor-context matching.
   Legacy destructive payloads show preview instead of mutating text.

Trust crossings: keyboard to App Group, app to Apple Speech, optional app to
the on-device model. Side effects: temporary protected files, local aggregate
counts, and text insertion into the active document.

## Cold start and manual recovery

| Item | Value |
| --- | --- |
| Actor | User tapping an outline microphone |
| Precondition | No fresh standby |
| Success | The request is saved and the user immediately receives a manual-open action (within three seconds); opening VoType from the Home Screen discovers it |
| Deny case | If the prompt is not visible within three seconds, keep the request recoverable and expose visible failure/Retry; no keyboard-side app-launch route is supported |

1. The keyboard persists the request, then exposes a manual-open recovery action;
   it does not call an unsupported keyboard-to-containing-app launch API.
2. A hot request without a matching acknowledgement falls back after the injected,
   cancellable 1.2-second timer. It stages a fresh manual UUID where it is not yet
   discoverable, durably cancels the old UUID while recording the replacement
   identity, then promotes the new request. A failed handoff exposes pending work
   or Retry, never false readiness.
3. The keyboard immediately presents the manual-open prompt, within the three-
   second recovery bound. The user opens VoType from the Home Screen; the request
   stays bounded by its 60-second expiry.

No route is allowed to remain indefinitely in a misleading “opening” state.

## App switch, extension recreation and result recovery

1. Before a session the keyboard stores only hashes of before/after/selected
   editor context, plus the session and time.
2. Automatic insertion requires a fresh snapshot, matching session and non-empty
   matching context evidence, and is limited to the same in-place extension
   instance.
3. A mismatch or recreated/manual session never auto-inserts. Explicit plain-text
   insertion requires no live selection, non-empty output text, the held session
   token and matching preview payload. It may target the current field chosen by
   the user. Confirmed replace/delete also require the original context,
   fingerprint and selection. Copy checks the consumed payload against its frozen
   preview. Discard validates the held token's peek against that preview before
   consuming its result. Neither requires editor-context matching.
4. Cancellation tombstones and terminal receipts reject late partials or a
   second terminal callback. A running hot adapter reconciles persisted
   cancellation, including during admission; its 0.5-second poll is best-effort
   while the process runs, not a suspension guarantee.

Side effects are limited to removing or consuming local session artifacts and,
only after the checks above, inserting text.

Unreadable cancellation evidence is not erased. An unresolved source-to-
replacement UUID anchor remains past ordinary eligibility until valid replacement
cancellation or terminal receipt; result-only payloads do not settle it. Orphan
stages are cleaned on ordinary lookup only after their retention boundary—there
is no background purge promise while the app is not running.

Signed physical-device microphone, Apple Speech, PiP lifecycle, extension eviction, and third-party insertion remain EXTERNAL / NOT_RUN for Slice A.

## Local Pinyin learning and deletion

1. Candidate generation reads the bundled Apache-2.0 lexicon locally.
2. Only an explicit selection of an existing candidate changes ranking.
3. Learning is bounded to 2,000 spellings and 16 candidates per spelling.
4. “Reset Pinyin candidate learning” deletes all learned counts and notifies the
   extension. It does not delete the bundled dictionary.

There is no network crossing or developer telemetry in this flow.

## Internal TestFlight publication

| Item | Value |
| --- | --- |
| Actor | Repository maintainer with Actions permission |
| Precondition | `main` evidence green; `publish=true`; valid distribution secrets |
| Success | Signed IPA accepted and processed by App Store Connect for internal testing |
| Deny case | Missing secret, profile mismatch, entitlement mismatch, invalid Info.plist, signing failure or test failure stops the job |

1. GitHub Actions checks secrets without printing them and creates an isolated
   temporary keychain.
2. Fastlane creates App Store profiles for the exact app and extension IDs.
3. The workflow verifies Team ID, Bundle IDs, App Group, certificate SHA,
   embedded profile UUID and nested signatures.
4. The signed IPA is retained as a versioned Actions artifact.
5. `pilot upload` sends the IPA to App Store Connect. Metadata/screenshots are
   skipped unless the separate `upload_metadata=true` gate is also chosen.
6. The workflow has no App Review submission step.
