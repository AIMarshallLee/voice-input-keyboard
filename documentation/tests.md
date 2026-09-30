# Verification map

## Existing coverage

### Slice A source evidence

The latest successful automated code evidence is [Build IPA #183](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/35538673741), successful on 2026-09-20 UTC for source
`b3be44b88cba83a5768af199ed30f2eec85fdaa6`. It ran 235 unit tests with 0
failures / 0 unexpected failures (53.643 seconds test time, 54.534 seconds
wall time) and four unique containing-app simulator UI cases under two schemes
(46.077 and 48.910 seconds). This is simulator UI smoke only: it is not keyboard,
microphone, Speech, PiP or cross-app physical-device coverage.

The same run passed `testTwentySequentialSessionRoundTripsLeaveNoStaleState`
(20 rounds, 1.470 seconds), `testFiftySequentialSessionsLeaveNoCrossSessionEffect`
(50 sessions, 0.839 seconds), and
`testConcurrentFinalCancelInterruptionAndTimeoutCommitOnce` (100 iterations,
2.006 seconds), as well as adapter contracts, foreground no-deep-link claim,
controlled three-second claim timeout, controlled 1.2-second hot fallback,
legacy decode, losing-consumer guard, generated plist validation and the keyboard
source gate. It also passed unsigned generic-device Release build and archive;
the workflow checked both `VoiceInputApp.app` and
`PlugIns/KeyboardExtension.appex`.

CI artifact `10613729361` (`VoType-IPA`, 5,241,187 bytes, 30-day retention) has
GitHub's outer artifact-ZIP SHA-256
`db2d5cc8d0e82596928d2002a8392ea677aef8128ddc7a8b1125b5e5e6805355`.
Independent downloaded-artifact inspection found contained IPA SHA-256
`59c882880c4875fa8d37f0090d53da893c23bc4390b8bf52271d2d97bff57a82`; these are
different layers and must not be substituted. Parsed IPA and archive plists show
main bundle `com.daseanle.votype`, extension
`com.daseanle.votype.keyboard`, version 1.0, build 183 and minimum iOS 16.0.
The unsigned IPA has no `_CodeSignature` or `embedded.mobileprovision`; Windows
did not run `codesign`, and this evidence does not assert installability or
signature verification. All Apple certificate/profile/signing/upload/metadata
steps were skipped, so this is not TestFlight evidence.

Signed physical-device microphone, Apple Speech, PiP lifecycle, extension eviction, and third-party insertion remain EXTERNAL / NOT_RUN for Slice A.

The latest merged-code evidence before this document set is [Build IPA #127](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/32870175097)
for commit `e8bfb57296ff4aab98b49b71adfe7b38fd744119`:
73 unit tests, 2 unique UI smoke tests, successful unsigned Release iphoneos
build, packaged IPA, and artifact ID `9572186636` (artifact ZIP SHA-256
`2bfa727b9661ab14b24a1dc591c7c5e2e1f711d90e78205ed7143bec64065835`).

The commercial-candidate branch adds a third UI privacy-disclosure test. [PR #8
Build IPA #129](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/32874031911)
for commit `19bb538e8a136c766150cb84a25eddec4520e8f4` passed 73 unit
tests and 3 UI tests, including the 20-round stress case and the new Apple
Speech fallback disclosure, then built and packaged the Release device IPA.

[PR #8 Build IPA #131](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/32876433386)
for commit `acea1f46a8dd4e1952ae80cb60b5464412139f37` reran all 73
unit and 3 UI tests, built the unsigned Release device app, and produced an
unsigned `.xcarchive` containing both the main app and Keyboard Extension.

The authoritative merged-code evidence is [main Build IPA #134](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/32884927580)
for commit `4aee78b880bc69d63f00272f74e9d7ae0c8989de`: all 73 unit
and 3 UI tests passed, as did the 20-round pressure case, unsigned Release
device build, archive bundle checks and artifact upload.

The historical signed distribution evidence for 1.0 (146) is [Build IPA #146](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/33088265846)
for source commit `01b3db482fb25821e8f4281ee66a3a8991e9051e`: 88 unit
and 4 UI tests passed, including setup-state and bounded PiP-startup regression
coverage. Both App Store profiles and both bundle signatures, entitlements,
App Group and profile UUIDs passed; Apple finished processing 1.0 (146) before
distributing it to Internal Testers. Build 137 was invalidated by real-device
feedback and is not the current candidate.

| Use case | Rule and negative case | Evidence | Status |
| --- | --- | --- | --- |
| Session IPC | Only matching, fresh sessions can read/write; cancellation and first terminal state reject late callbacks | `DictationConstantsTests.swift` | Existing automated unit |
| Unified engine ownership | One actor owns permission/audio/Speech/deadline/terminal state; only the synchronous gate appends PCM and adapters cannot create competing sessions | Engine and adapter contract tests in CI #183 | Existing automated unit |
| Foreground admission | Discovery works without deep link; peek precedes exact atomic claim; a claim miss within three seconds denies engine start and preserves recovery; the returned event stream begins with the matching `.authorizing` event | Foreground claim / `.authorizing` tests in CI #183 | Existing automated unit |
| Hot handoff | Matching injected acknowledgement cancels its 1.2-second timer; timeout stages an undiscoverable replacement, durably cancels the old UUID with replacement identity, then promotes; no false readiness is exposed | Hot fallback and handoff tests in CI #183 | Existing automated unit |
| Held result safety | Manual/recreated/empty/destructive results remain held; auto-insert requires matching in-place context in the same extension instance; explicit plain insert requires token, no selection, non-empty text and matching consumed preview; confirmed replace/delete also require context, fingerprint and selection; copy compares consumed payload with its frozen preview, while discard validates the held token's peek before consuming; neither requires editor-context matching | Recovery, legacy decode and losing-consumer tests in CI #183 | Existing automated unit |
| 20-round pressure | Twenty sequential settings/live/result/consume cycles leave no stale state | `testTwentySequentialSessionRoundTripsLeaveNoStaleState` | Existing automated unit |
| Editor recovery | Auto-insert requires an in-place same-instance insert, no selected text, and fresh matching non-empty context evidence; mismatch/empty editor denies | `KeyboardSessionRecoveryTests.swift` | Existing automated unit |
| Voice launch state | Fresh standby is hot; unresponsive hot path goes cold and every route ends with manual recovery | `DictationLaunchPolicyTests.swift` | Existing automated unit |
| Pinyin quality | Common phrases rank Top-1, learning is bounded/persistent/resettable, fabricated candidates denied | `PinyinInputEngineTests.swift` | Existing automated unit |
| Pinyin latency | Warm-query p95 stays below 40 ms in the test environment | `testBundledLexiconWarmQueryP95IsUnderFortyMilliseconds` | Existing automated performance gate |
| Text processing | Delete is a dedicated result, empty results fail, per-session language/translation settings are honored | `TextProcessorTests.swift` | Existing automated unit |
| Host disclosures | Standby shows mic-off state, Pinyin reset is discoverable, and Speech copy distinguishes device processing from Apple service fallback | `VoTypeUITests.swift` | Existing simulator UI smoke |
| App Store Info.plist | Unknown `UIBackgroundModes` values fail before build/upload | `scripts/tests/test_validate_distribution_info.py`, workflow step 6 | Existing automated CI gate |
| Device package | Main app and extension compile for generic iphoneos; an IPA and `.xcarchive` containing both bundles are produced | Main Build #134 steps 16-19 | Existing automated build/archive gate |
| Distribution signature | Team, Bundle IDs, App Group, signer SHA and profile UUID match | Historical Build #146 steps 20-23 for 1.0 (146) | Historical guarded live gate passed; not Slice A distribution evidence |

The workflow runs on every pull request and `main` push. Repository branch
protection settings were not audited here, so “CI-required” means the project
release process waits for a green run; it does not claim GitHub has technically
blocked every possible direct push.

## Proposed tests

| Use case | Expected behavior / deny case | Type | Status |
| --- | --- | --- | --- |
| Signed candidate install | App and extension install, launch and access the App Group on minimum/current/iOS 26/iPad devices | Guarded live | Proposed final-device gate |
| Keyboard accessibility | Controls, candidate/status text and recovery actions have explicit labels/hints in source; real VoiceOver focus/order remains device-dependent | Source audit + compile; physical-device VoiceOver | Labels implemented; physical-device gate EXTERNAL / NOT_RUN |
| PiP standby | Explicit start creates visible truthful PiP, mic remains off, stop clears readiness within 3.5 s | Manual review + guarded live | Proposed final-device gate |
| Third-party app insertion | Hot and cold paths insert once into WeChat, Notes and a browser without cross-field recovery | Manual review | Proposed final-device gate |
| Permissions | First grant, deny, revoke, Settings re-grant and Full Access off all recover/fail closed | Manual review | Proposed final-device gate |
| Speech environment | Online/offline, unsupported locale, silence, long utterance and Apple service outage are accurately reported | Guarded live | Proposed |
| Audio interruption | Phone/Siri/Bluetooth/headset/media reset leaves no stuck mic and next session works | Manual review | Proposed final-device gate |
| Resource budget | Keyboard peak memory <45 MB; standby/recording energy and mic indicators match disclosure | Instruments/manual review | Proposed final-device gate |
| Store materials | Every localized string and screenshot matches the installed candidate at 100% scale | Manual review | Proposed submission gate |
| App Store processing | Uploaded build completes processing and is assigned to internal testers | Historical Build #146 step 25 for 1.0 (146) | Historical guarded live gate passed; not Slice A distribution evidence |

## Gaps

| Priority | Unverified rule | Exposure |
| --- | --- | --- |
| Blocker | Final signed candidate has not completed the full device matrix | User-facing reliability and App Group behavior |
| Blocker | PiP use has not been accepted by App Review | Store eligibility |
| Blocker | Historical screenshots are not valid submission evidence | Misleading or rejected store page |
| High | Memory <45 MB and energy behavior have no automated measurement | Extension termination and battery cost |
| High | Cold-launch responder compatibility is device/app dependent | Voice button may require manual recovery |
| High | Audio route/interruption matrix is not automated | Stuck or failed subsequent sessions |
| High | Offline recognition and permission-denial recovery are not exercised against real Apple services/settings | Misleading availability or unrecoverable voice flow |
| High | Custom keyboard VoiceOver behavior has no physical-device evidence | Inaccessible core input path |
| Medium | Swift actor-isolation warnings remain under Swift 5.9 | Future Swift 6 build/runtime risk |

Simulator/CI evidence must never be substituted for any final-device or App
Review item above.
