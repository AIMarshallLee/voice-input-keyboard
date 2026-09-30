# Changelog

All notable user-facing changes are recorded here. VoType remains a 1.0
commercial candidate until final device testing and App Review are complete.

## Unreleased — Slice A

### Improvements

- Voice permission, recording, Speech recognition, timeout and terminal state now
  have one session owner; foreground and PiP use the same session engine.
- Foreground recovery discovers pending work without a deep link, claims it before
  calling `engine.start`; the returned stream must begin with the matching
  `.authorizing` event. Cold recovery saves the request and shows a manual-open
  action rather than trying to launch the app from the keyboard.
- Timed-out hot requests stage an undiscoverable fresh manual UUID, durably cancel
  the old UUID with its replacement identity, then promote the new request.
- Auto-insertion is limited to a matching in-place session in the same extension
  instance, with no selection, non-empty matching context and an unconfirmed
  cursor insertion. Manual/recreated sessions, empty text and destructive or
  confirmation-required operations stay held; explicit plain-text insertion can
  target the user's current field, while confirmed replace/delete requires
  matching context, fingerprint and selection. Copy compares the consumed result
  with the frozen preview; discard validates the held token's preview before
  consuming its result. Neither requires editor-context matching.

Signed physical-device microphone, Apple Speech, PiP lifecycle, extension eviction, and third-party insertion remain EXTERNAL / NOT_RUN for Slice A.

## 1.0 candidate — 2026-08-26

### New features

- **In-place voice standby:** Users can explicitly enable a visible PiP standby,
  then start a session from the keyboard without switching apps while standby is
  active. Standby clearly says the microphone is off.
- **Chinese Pinyin keyboard:** Continuous Pinyin, candidate selection, local
  adaptive ranking, reset, English mode, numbers, symbols and hold-to-delete are
  available when voice input is not appropriate.
- **Live session feedback:** The keyboard shows starting, listening, partial text
  and processing states, and the microphone can be tapped again to stop.

### Improvements

- Voice requests/results are isolated by session with expiry, cancellation and
  editor-context checks to reduce stale or cross-field insertion.
- Unresponsive in-place requests fall back to cold launch, then show an explicit
  manual-open action instead of waiting indefinitely.
- Common Pinyin phrases rank ahead of fragmented character composition, and
  explicit selections persist locally within bounded storage.
- App-switch, extension-recreation and audio-interruption recovery are safer and
  user-visible.

### Fixes

- Installation setup now reflects keyboard/full-access observations reported by
  the keyboard extension instead of leaving the first two steps incomplete.
- In-place voice standby now checks current PiP availability and exits with a
  retryable error after four seconds instead of waiting indefinitely when iOS
  does not start Picture in Picture.
- Fixed an App Store Connect rejection caused by the invalid
  `picture-in-picture` Info.plist background-mode value; the supported `audio`
  mode is used for Audio/AirPlay/PiP capability.
- Fixed per-session language, punctuation and translation settings, voice-delete
  handling, spoken self-correction and permission-error recovery.

### Required user action

- Add the VoType keyboard, enable Allow Full Access for local App Group exchange,
  and grant microphone and Speech permission before using voice input.
- In-place standby is optional and must be started explicitly from VoType.
