# Verification map

## Existing coverage

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

| Use case | Rule and negative case | Evidence | Status |
| --- | --- | --- | --- |
| Session IPC | Only matching, fresh sessions can read/write; cancellation and first terminal state reject late callbacks | `DictationConstantsTests.swift` | Existing automated unit |
| 20-round pressure | Twenty sequential settings/live/result/consume cycles leave no stale state | `testTwentySequentialSessionRoundTripsLeaveNoStaleState` | Existing automated unit |
| Editor recovery | Auto-insert requires fresh matching hashes and non-empty evidence; mismatch/empty editor denies | `KeyboardSessionRecoveryTests.swift` | Existing automated unit |
| Voice launch state | Fresh standby is hot; unresponsive hot path goes cold and every route ends with manual recovery | `DictationLaunchPolicyTests.swift` | Existing automated unit |
| Pinyin quality | Common phrases rank Top-1, learning is bounded/persistent/resettable, fabricated candidates denied | `PinyinInputEngineTests.swift` | Existing automated unit |
| Pinyin latency | Warm-query p95 stays below 40 ms in the test environment | `testBundledLexiconWarmQueryP95IsUnderFortyMilliseconds` | Existing automated performance gate |
| Text processing | Delete is a dedicated result, empty results fail, per-session language/translation settings are honored | `TextProcessorTests.swift` | Existing automated unit |
| Host disclosures | Standby shows mic-off state, Pinyin reset is discoverable, and Speech copy distinguishes device processing from Apple service fallback | `VoTypeUITests.swift` | Existing simulator UI smoke |
| App Store Info.plist | Unknown `UIBackgroundModes` values fail before build/upload | `scripts/tests/test_validate_distribution_info.py`, workflow step 6 | Existing automated CI gate |
| Device package | Main app and extension compile for generic iphoneos and an IPA artifact is produced | Build #127 steps 16-18 | Existing automated build gate |
| Distribution signature | Team, Bundle IDs, App Group, signer SHA and profile UUID match | `build.yml` distribution steps; last successful evidence build 115 | Existing guarded live gate |

The workflow runs on every pull request and `main` push. Repository branch
protection settings were not audited here, so “CI-required” means the project
release process waits for a green run; it does not claim GitHub has technically
blocked every possible direct push.

## Proposed tests

| Use case | Expected behavior / deny case | Type | Status |
| --- | --- | --- | --- |
| Signed candidate install | App and extension install, launch and access the App Group on minimum/current/iOS 26/iPad devices | Guarded live | Proposed final-device gate |
| PiP standby | Explicit start creates visible truthful PiP, mic remains off, stop clears readiness within 3.5 s | Manual review + guarded live | Proposed final-device gate |
| Third-party app insertion | Hot and cold paths insert once into WeChat, Notes and a browser without cross-field recovery | Manual review | Proposed final-device gate |
| Permissions | First grant, deny, revoke, Settings re-grant and Full Access off all recover/fail closed | Manual review | Proposed final-device gate |
| Speech environment | Online/offline, unsupported locale, silence, long utterance and Apple service outage are accurately reported | Guarded live | Proposed |
| Audio interruption | Phone/Siri/Bluetooth/headset/media reset leaves no stuck mic and next session works | Manual review | Proposed final-device gate |
| Resource budget | Keyboard peak memory <45 MB; standby/recording energy and mic indicators match disclosure | Instruments/manual review | Proposed final-device gate |
| Store materials | Every localized string and screenshot matches the installed candidate at 100% scale | Manual review | Proposed submission gate |
| App Store processing | Uploaded build completes processing and is assigned to internal testers | Guarded live | Proposed per release |

## Gaps

| Priority | Unverified rule | Exposure |
| --- | --- | --- |
| Blocker | Final signed candidate has not completed the full device matrix | User-facing reliability and App Group behavior |
| Blocker | PiP use has not been accepted by App Review | Store eligibility |
| Blocker | Historical screenshots are not valid submission evidence | Misleading or rejected store page |
| High | Memory <45 MB and energy behavior have no automated measurement | Extension termination and battery cost |
| High | Cold-launch responder compatibility is device/app dependent | Voice button may require manual recovery |
| High | Audio route/interruption matrix is not automated | Stuck or failed subsequent sessions |
| Medium | Swift actor-isolation warnings remain under Swift 5.9 | Future Swift 6 build/runtime risk |

Simulator/CI evidence must never be substituted for any final-device or App
Review item above.
