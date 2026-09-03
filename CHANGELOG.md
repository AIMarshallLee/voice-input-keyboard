# Changelog

All notable user-facing changes are recorded here. VoType remains a 1.0
commercial candidate until final device testing and App Review are complete.

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
