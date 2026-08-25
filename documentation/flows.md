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
3. The app consumes only the newest fresh request, switches readiness to
   recording, activates `AVAudioSession`, and starts `AVAudioEngine`.
4. Apple Speech receives audio. Partial transcript state is throttled to about
   five protected App Group writes per second.
5. Text processing uses local rules and, when explicitly enabled and available,
   the on-device Foundation Model. The first terminal state wins.
6. The keyboard checks UUID and freshness, inserts the result, records a
   terminal receipt and removes consumable text files.

Trust crossings: keyboard to App Group, app to Apple Speech, optional app to
the on-device model. Side effects: temporary protected files, local aggregate
counts, and text insertion into the active document.

## Cold start and manual recovery

| Item | Value |
| --- | --- |
| Actor | User tapping an outline microphone |
| Precondition | No fresh standby |
| Success | Containing app starts the pending session, or the user receives an explicit manual-open action |
| Deny case | No supported opening route responds within three seconds |

1. The keyboard persists the request before attempting the `votype://` URL.
2. A hot request without response falls back after 1.2 seconds.
3. The extension tries `NSExtensionContext.open` and a responder-chain
   compatibility path. Neither is assumed to succeed.
4. At three seconds, the keyboard tells the user to open VoType from the Home
   Screen. The request stays bounded by its 60-second expiry.

No route is allowed to remain indefinitely in a misleading “opening” state.

## App switch, extension recreation and result recovery

1. Before a session the keyboard stores only hashes of before/after/selected
   editor context, plus the session and time.
2. On recreation it requires a fresh snapshot, matching session and matching
   non-empty context evidence before automatic insertion.
3. A mismatch never auto-inserts. The user may explicitly accept or discard a
   recovered result.
4. Cancellation tombstones and terminal receipts reject late partials or a
   second terminal callback.

Side effects are limited to removing or consuming local session artifacts and,
only after the checks above, inserting text.

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

