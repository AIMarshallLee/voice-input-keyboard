# Slice A Reliable Session Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the two divergent recording implementations with one deterministic dictation engine, preserve backward-compatible IPC, remove unsupported keyboard-to-host launching, and leave the app in an unsigned Release/archive-green state.

**Architecture:** One actor-isolated `DictationSessionEngine` owns session state and delegates Apple frameworks, scheduling, text processing, and IPC to narrow ports. `DictationViewModel` and `BackgroundDictationManager` become presentation/transport adapters over the same production engine instance; the keyboard never launches the containing app and always holds manual-recovery results for an explicit insert, copy, or discard action.

**Tech Stack:** Swift 5.9, Swift Concurrency (`actor`, `AsyncStream`), SwiftUI, UIKit, AVFoundation, Speech, App Group atomic files, Darwin notifications, XCTest, XcodeGen, GitHub Actions on macOS 26.

**Spec:** `docs/superpowers/specs/2026-09-04-voice-first-commercial-v1-design.md`

## Global Constraints

- Minimum deployment target remains iOS 16.0 and Swift remains 5.9.
- `project.yml` remains the only source of truth for the generated Xcode project; do not commit `VoType.xcodeproj`.
- `SessionToken` is a random UUID only; process-local engine generation is never serialized.
- One actor-isolated `finish` operation is the only terminal commit point; `completed` is emitted only after atomic output persistence succeeds.
- Audio buffers use one synchronous/direct path with a stop/cancel barrier; never create a `Task` per audio buffer.
- `stop` while listening enters processing; `stop` while authorizing or preparing cancels; `stop` while processing is a no-op; `cancel` from any active phase ends cancelled.
- An interruption, lost input route, or media-services reset fails the active session once; Slice A adds no implicit pause/resume behavior.
- Foreground permission policy may request unresolved permissions; PiP/in-place permission policy reads status only and never presents permission UI.
- Distribution code never calls responder-chain `openURL` or `NSExtensionContext.open` from the keyboard extension.
- Without fresh PiP readiness, the keyboard queues the UUID-scoped request and immediately asks the user to open VoType manually.
- A manual-open result is always held for explicit insert, copy, or discard; a destructive legacy result decodes to `previewOnly` and never bypasses confirmation.
- App Group files and Darwin notifications remain the transport; raw audio is never persisted.
- Existing text-processing algorithms remain unchanged; Slice A only makes their per-session voice-edit input explicit. Pinyin ranking, keyboard Voice/Type redesign, setup heartbeat, editor-epoch tracking, diagnostics, and App Store submission are outside Slice A.
- Simulator and unsigned archive evidence never substitutes for signed physical-device microphone, PiP, extension-lifecycle, or third-party insertion testing; those remain `EXTERNAL / NOT_RUN`.

## Scope Boundary and Exit Evidence

Slice A ends only when both entry adapters use the same engine, lifecycle/race/timeout tests pass, the source gate proves that no distribution keyboard launch path remains, and the unsigned generic-device Release build and archive contain both `VoiceInputApp.app` and `KeyboardExtension.appex`. It does not upload TestFlight.

Deferred work is explicit:

- Slice B owns the simple Voice/Type surface, field layouts, and commercial Pinyin baseline.
- Slice C owns the complete editor epoch, all four text/selection callbacks, selected-text intent quality, and voice-quality corpora.
- Slice D owns the bounded diagnostic ring, static PiP/no-PiP release switch, signed device matrix, and a newly authorized TestFlight candidate.

## File Map

### New production files

- `Shared/DictationSessionModels.swift` — canonical UUID token, immutable request snapshot, ordered event, failure, and `EditPlan` contracts shared by app and keyboard.
- `VoiceInputApp/DictationSessionDependencies.swift` — narrow engine port protocols and deadline constants.
- `VoiceInputApp/DictationAudioBufferGate.swift` — synchronous append path and close barrier around the live recognition request.
- `VoiceInputApp/DictationSessionEngine.swift` — sole actor-isolated session state machine and terminal coordinator.
- `VoiceInputApp/AppleDictationAdapters.swift` — production wrappers for permissions, audio session/capture, Speech, notifications, text processing, and Darwin output.
- `VoiceInputApp/DictationSessionEnvironment.swift` — one production composition root and one shared engine instance.
- `Shared/DictationHotAckCoordinator.swift` — injected 1.2-second in-place acknowledgement timer with cancellable production scheduling.
- `Shared/KeyboardResultDispositionPolicy.swift` — pure automatic/held disposition and pre-consume/post-consume edit validation.
- `KeyboardExtension/HeldResultActionView.swift` — compact, accessible insert/copy/discard action row for held results.
- `scripts/verify_distribution_keyboard_launch.sh` — deterministic source gate rejecting keyboard-side app launch APIs.

### New test files

- `VoTypeTests/DictationSessionModelsTests.swift` — token and new/legacy wire-format coverage.
- `VoTypeTests/DictationAudioBufferGateTests.swift` — direct append and close/cancel barrier coverage.
- `VoTypeTests/DictationSessionTestDoubles.swift` — deterministic fake ports reused by engine and adapter tests.
- `VoTypeTests/DictationSessionEngineTests.swift` — transition, command, deadline, stale-callback, race, and 50-session tests.
- `VoTypeTests/AppleDictationAdaptersTests.swift` — permission-decision, text-plan mapping, and Darwin output coverage.
- `VoTypeTests/BackgroundDictationManagerTests.swift` — PiP/in-place adapter contract.
- `VoTypeTests/DictationCoordinatorTests.swift` — ordinary no-deep-link foreground presentation and hot-timeout replacement claim contract.
- `VoTypeTests/DictationHotAckCoordinatorTests.swift` — controlled 1.2-second hot acknowledgement and stale-token coverage.
- `VoTypeTests/KeyboardResultDispositionPolicyTests.swift` — hot versus manual result disposition and destructive fail-closed behavior.

### Existing files modified

- `Shared/DictationConstants.swift` — bridge legacy string callers through validated `SessionToken`.
- `Shared/DarwinBridge.swift` — encode `EditPlan`, decode legacy `deleteSelected`, expose typed terminal commit outcomes, and move a timed-out consumed hot request to a fresh manual UUID while tombstoning the old one.
- `Shared/TextProcessor.swift` — accept the captured voice-edit flag as an explicit typed-session input without changing processing algorithms.
- `Shared/DictationLaunchPolicy.swift` — replace automatic host opening with immediate manual recovery.
- `Shared/KeyboardSessionRecovery.swift` — persist launch mode and one combined, privacy-preserving context fingerprint with safe legacy defaults.
- `VoiceInputApp/BackgroundDictationManager.swift` — remove AVFoundation/Speech ownership and adapt Darwin/PiP events to the shared engine.
- `VoiceInputApp/DictationView.swift` — remove AVFoundation/Speech ownership and adapt SwiftUI state to the shared engine stream.
- `VoiceInputApp/VoiceInputApp.swift` — preserve normal pending-request presentation and inject the shared production environment.
- `KeyboardExtension/KeyboardViewController.swift` — remove all programmatic host launch code, persist manual mode, and apply `EditPlan` only after prevalidation and explicit confirmation when required.
- `VoTypeTests/DictationConstantsTests.swift` — retain existing IPC/replay coverage and add typed commit, legacy cleanup, and losing-consumer assertions.
- `VoTypeTests/DictationLaunchPolicyTests.swift` — assert immediate manual recovery and the 1.2-second hot-path boundary.
- `VoTypeTests/DictationViewModelTests.swift` — replace direct recorder assumptions with presentation-adapter contract assertions.
- `VoTypeTests/TextProcessorTests.swift` — prove voice-edit uses the immutable session snapshot rather than a changed live default.
- `.github/workflows/build.yml` — run the unsupported-launch source gate before tests/build/archive.
- `README.md`, `CHANGELOG.md`, `documentation/architecture.md`, `documentation/flows.md`, `documentation/tests.md`, `documentation/first-run-and-recovery.md`, `docs/release-checklist.md` — document only behavior and fresh evidence delivered by Slice A.

## Execution Conventions

Run all Xcode commands on a macOS host with the repository root as the working directory. Establish one simulator and one non-production build number at the start of each execution session:

```bash
SIM_ID="$(xcrun simctl list devices available -j | /usr/bin/python3 -c 'import json,sys; data=json.load(sys.stdin); print(next(d["udid"] for runtime in data["devices"].values() for d in runtime if d.get("isAvailable") and "iPhone" in d.get("name", "")))')"
test -n "$SIM_ID"
PLAN_BUILD_NUMBER=9001
xcodegen generate
```

For a single XCTest method, use this exact form and replace only the final test identifier with the method named in that step:

```bash
xcodebuild test \
  -project VoType.xcodeproj \
  -scheme VoTypeTests \
  -destination "platform=iOS Simulator,id=$SIM_ID" \
  CODE_SIGNING_ALLOWED=NO \
  CURRENT_PROJECT_VERSION="$PLAN_BUILD_NUMBER" \
  -only-testing:VoTypeTests/DictationSessionModelsTests/testGeneratedAndDecodedTokensRequireUUIDs \
  -derivedDataPath ./slice_a_test_build
```

Expected failure means an assertion failure, a missing symbol named by the step, or a deliberate source-gate violation. Build-environment failures do not count as a red test.

---

### Task 1: Canonical Session and Backward-Compatible IPC Contracts

**Files:**
- Create: `Shared/DictationSessionModels.swift`
- Create: `VoTypeTests/DictationSessionModelsTests.swift`
- Modify: `Shared/DictationConstants.swift:3-24`
- Modify: `Shared/DarwinBridge.swift:136-181, 433-472, 1114-1215`
- Modify: `VoTypeTests/DictationConstantsTests.swift:35-645`

**Interfaces:**
- Consumes: existing `DictationSettings`, `DictationIPCResult`, App Group atomic write/receipt behavior, and `TextProcessingResult`.
- Produces: `SessionToken`, `DictationSessionRequest`, `DictationSessionEventEnvelope`, `DictationFailure`, `EditPlan`, `DictationTerminal`, `DictationOutputCommitStatus`, `DarwinBridge.commit(_:token:timestamp:)`, and safe legacy decoding used by every later task.

- [x] **Step 1: Write failing token and wire-format tests**

Create `VoTypeTests/DictationSessionModelsTests.swift` with these cases:

```swift
import XCTest
@testable import VoiceInputApp

final class DictationSessionModelsTests: XCTestCase {
    func testGeneratedAndDecodedTokensRequireUUIDs() throws {
        let generated = SessionToken()
        XCTAssertNotNil(UUID(uuidString: generated.rawValue))
        XCTAssertNil(SessionToken(rawValue: "not-a-uuid"))

        let data = try JSONEncoder().encode(generated)
        XCTAssertEqual(try JSONDecoder().decode(SessionToken.self, from: data), generated)
        XCTAssertThrowsError(
            try JSONDecoder().decode(SessionToken.self, from: Data(#""not-a-uuid""#.utf8))
        )
    }

    func testNewCompletedPayloadRoundTripsEditPlanWithoutLegacyFlag() throws {
        let token = SessionToken()
        let plan = EditPlan(
            intent: .dictate,
            operation: .insertAtCursor,
            text: "你好",
            expectedContextFingerprint: "context-digest",
            requiresConfirmation: false
        )
        let result = DictationIPCResult(
            status: .completed,
            text: plan.text,
            token: token,
            editPlan: plan,
            timestamp: 100
        )

        let data = try JSONEncoder().encode(result)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("editPlan"))
        XCTAssertFalse(json.contains("deleteSelected"))
        XCTAssertEqual(try JSONDecoder().decode(DictationIPCResult.self, from: data), result)
    }

    func testLegacyInsertPayloadDecodesAsInsertAtCursor() throws {
        let session = UUID().uuidString
        let json = """
        {"status":"completed","text":"旧结果","session":"\(session)","deleteSelected":false,"timestamp":100}
        """
        let decoded = try JSONDecoder().decode(
            DictationIPCResult.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.editPlan?.operation, .insertAtCursor)
        XCTAssertEqual(decoded.editPlan?.requiresConfirmation, false)
    }

    func testLegacyDestructivePayloadDecodesAsPreviewOnly() throws {
        let session = UUID().uuidString
        let json = """
        {"status":"completed","text":"替换结果","session":"\(session)","deleteSelected":true,"timestamp":100}
        """
        let decoded = try JSONDecoder().decode(
            DictationIPCResult.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.editPlan?.operation, .previewOnly)
        XCTAssertEqual(decoded.editPlan?.requiresConfirmation, true)
        XCTAssertFalse(decoded.deleteSelected)
    }

    func testResultPayloadRejectsNonUUIDSession() {
        let json = """
        {"status":"completed","text":"结果","session":"not-a-uuid","deleteSelected":false,"timestamp":100}
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(DictationIPCResult.self, from: Data(json.utf8))
        )
    }
}
```

- [x] **Step 2: Run the focused tests and confirm the contract is absent**

Run the single-test command from “Execution Conventions” for all five methods in `DictationSessionModelsTests`.

Expected: FAIL because `SessionToken`, `EditPlan`, and the new `DictationIPCResult` initializer do not exist.

- [x] **Step 3: Add the canonical models**

Create `Shared/DictationSessionModels.swift` with these exact public-to-module shapes:

```swift
import Foundation

struct SessionToken: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String

    init() {
        rawValue = UUID().uuidString
    }

    init?(rawValue: String) {
        guard UUID(uuidString: rawValue) != nil else { return nil }
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard UUID(uuidString: value) != nil else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "SessionToken must contain a UUID"
            )
        }
        rawValue = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum DictationEntryPoint: String, Codable, Equatable, Sendable {
    case foreground
    case inPlace
}

enum DictationAuthorizationPolicy: String, Codable, Equatable, Sendable {
    case requestIfNeeded
    case readOnly
}

struct TextProcessingSnapshot: Equatable, Sendable {
    let selectedText: String?
    let keyboardType: Int
    let language: String
    let translateEnabled: Bool
    let translateTarget: String
    let voiceEditEnabled: Bool
    let livePreviewEnabled: Bool
    let expectedContextFingerprint: String?
}

struct DictationSessionRequest: Equatable, Sendable {
    let token: SessionToken
    let entryPoint: DictationEntryPoint
    let authorizationPolicy: DictationAuthorizationPolicy
    let whisper: Bool
    let processing: TextProcessingSnapshot
}

enum EditIntent: Codable, Equatable, Sendable {
    case dictate
    case append
    case rewrite
    case translate(targetLanguage: String)
    case delete
}

enum EditOperation: String, Codable, Equatable, Sendable {
    case insertAtCursor
    case replaceSelection
    case deleteSelection
    case previewOnly
}

struct EditPlan: Codable, Equatable, Sendable {
    let intent: EditIntent
    let operation: EditOperation
    let text: String
    let expectedContextFingerprint: String?
    let requiresConfirmation: Bool
}

enum DictationPermissionKind: String, Equatable, Sendable {
    case speech
    case microphone
}

enum DictationFailure: Error, Equatable, Sendable {
    case permissionDenied(DictationPermissionKind)
    case permissionRequiresForeground(DictationPermissionKind)
    case recognitionUnavailable
    case audioSession
    case audioCapture
    case recognition
    case noSpeech
    case startTimeout
    case finalizationTimeout
    case processing
    case processingTimeout
    case interrupted
    case inputRouteLost
    case mediaServicesReset
    case outputPersistence
}

extension DictationFailure {
    var userMessage: String {
        switch self {
        case .permissionDenied(.speech), .permissionRequiresForeground(.speech):
            return "请在系统设置中允许语音识别"
        case .permissionDenied(.microphone), .permissionRequiresForeground(.microphone):
            return "请在系统设置中允许麦克风"
        case .recognitionUnavailable:
            return "语音识别不可用，请检查网络或设备端识别支持"
        case .audioSession, .audioCapture:
            return "无法启动麦克风，请重试"
        case .recognition:
            return "语音识别失败，请重试"
        case .noSpeech:
            return "未识别到语音"
        case .startTimeout:
            return "语音启动超时，请重试"
        case .finalizationTimeout:
            return "完成识别超时，请重试"
        case .processing:
            return "文字处理失败，请重试"
        case .processingTimeout:
            return "文字处理超时，请重试"
        case .interrupted:
            return "录音被系统中断，请重试"
        case .inputRouteLost:
            return "麦克风连接已变化，请重试"
        case .mediaServicesReset:
            return "音频服务已重置，请重试"
        case .outputPersistence:
            return "无法保存识别结果，请重试"
        }
    }
}

enum DictationSessionEvent: Equatable, Sendable {
    case authorizing
    case preparing
    case listening(partial: String)
    case processing
    case completed(EditPlan)
    case failed(DictationFailure)
    case cancelled
}

struct DictationSessionEventEnvelope: Equatable, Sendable {
    let token: SessionToken
    let sequence: UInt64
    let event: DictationSessionEvent
}

enum DictationTerminal: Equatable, Sendable {
    case completed(EditPlan)
    case failed(DictationFailure)
    case cancelled
}

enum DictationOutputCommitStatus: Equatable, Sendable {
    case written
    case alreadyTerminal
    case cancelled
    case ioFailure
}
```

Update `DictationConstants.isValidSession` to delegate to `SessionToken(rawValue:)`, while retaining the string API for existing callers:

```swift
static func isValidSession(_ session: String) -> Bool {
    SessionToken(rawValue: session) != nil
}
```

- [x] **Step 4: Implement new encoding and safe legacy decoding**

Add `expectedContextFingerprint: String? = nil` to `DictationSettings` and its initializer. Replace the stored `deleteSelected` field in `DictationIPCResult` with `editPlan: EditPlan?`, a safe computed compatibility view, and custom `Codable`:

```swift
struct DictationIPCResult: Codable, Equatable {
    enum Status: String, Codable {
        case completed
        case error
    }

    let status: Status
    let text: String
    let session: String
    let editPlan: EditPlan?
    let timestamp: TimeInterval

    var transcription: String? { status == .completed ? text : nil }
    var error: String? { status == .error ? text : nil }
    var deleteSelected: Bool {
        editPlan?.operation == .replaceSelection
            || editPlan?.operation == .deleteSelection
    }

    private enum CodingKeys: String, CodingKey {
        case status, text, session, editPlan, deleteSelected, timestamp
    }

    init(
        status: Status,
        text: String,
        token: SessionToken,
        editPlan: EditPlan?,
        timestamp: TimeInterval
    ) {
        self.status = status
        self.text = text
        self.session = token.rawValue
        self.editPlan = editPlan
        self.timestamp = timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(Status.self, forKey: .status)
        text = try container.decode(String.self, forKey: .text)
        session = try container.decode(String.self, forKey: .session)
        guard SessionToken(rawValue: session) != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .session,
                in: container,
                debugDescription: "Result session must contain a UUID"
            )
        }
        timestamp = try container.decode(TimeInterval.self, forKey: .timestamp)

        if let plan = try container.decodeIfPresent(EditPlan.self, forKey: .editPlan) {
            editPlan = plan
        } else if status == .completed {
            let destructive = try container.decodeIfPresent(
                Bool.self,
                forKey: .deleteSelected
            ) ?? false
            editPlan = EditPlan(
                intent: destructive ? .rewrite : .dictate,
                operation: destructive ? .previewOnly : .insertAtCursor,
                text: text,
                expectedContextFingerprint: nil,
                requiresConfirmation: destructive
            )
        } else {
            editPlan = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(text, forKey: .text)
        try container.encode(session, forKey: .session)
        try container.encodeIfPresent(editPlan, forKey: .editPlan)
        try container.encode(timestamp, forKey: .timestamp)
    }
}
```

Expose a typed commit method in `DarwinBridge` and keep the existing Bool-returning methods as deprecated compatibility wrappers until Tasks 6 and 7 remove their call sites:

```swift
static func commit(
    _ terminal: DictationTerminal,
    token: SessionToken,
    timestamp: TimeInterval = Date().timeIntervalSince1970
) -> DictationOutputCommitStatus
```

Add a non-consuming exact lookup for the foreground manual path:

```swift
static func peekDictationSettings(
    expectedSession: String,
    now: TimeInterval = Date().timeIntervalSince1970,
    maxAge: TimeInterval = settingsMaxAge
) -> DictationSettings?
```

Add `DarwinNotificationName.requestCancelDictation = "com.daseanle.votype.requestCancelDictation"`. It is always session-scoped through `postSessionNotification`/`sessionNotificationName` and means “cancel this engine generation from any active phase”; it is distinct from the existing stop command, whose processing-phase behavior remains a no-op.

It validates `SessionToken(rawValue:)`, reads only that UUID's settings file under the existing session lock, rejects cancellation, and verifies the decoded `settings.session` equals `expectedSession`. Change private filename/session hashing to require `SessionToken(rawValue:)` before producing any settings, live, result, cancellation, receipt, or notification filename.

Map `.completed(plan)` to a completed `DictationIPCResult`, `.failed(failure)` to `failure.userMessage`, and `.cancelled` to the existing cancellation tombstone without creating a transcription payload. Rename private `TerminalWriteOutcome` to the shared `DictationOutputCommitStatus` type. Keep first-writer-wins, terminal receipt, cancellation, and atomic write behavior unchanged.

- [x] **Step 5: Add typed commit regression tests**

Append focused cases to `VoTypeTests/DictationConstantsTests.swift`:

```swift
func testTypedCompletedCommitIsFirstWriterWins() throws {
    let token = SessionToken()
    let plan = EditPlan(
        intent: .dictate,
        operation: .insertAtCursor,
        text: "第一次",
        expectedContextFingerprint: nil,
        requiresConfirmation: false
    )
    XCTAssertEqual(DarwinBridge.commit(.completed(plan), token: token), .written)
    XCTAssertEqual(DarwinBridge.commit(.failed(.recognition), token: token), .alreadyTerminal)
    XCTAssertEqual(
        DarwinBridge.peekResult(expectedSession: token.rawValue)?.editPlan,
        plan
    )
}

func testTypedCancelledCommitCreatesNoResult() {
    let token = SessionToken()
    XCTAssertEqual(DarwinBridge.commit(.cancelled, token: token), .cancelled)
    XCTAssertNil(DarwinBridge.peekResult(expectedSession: token.rawValue))
    XCTAssertEqual(
        DarwinBridge.commit(
            .completed(
                EditPlan(
                    intent: .dictate,
                    operation: .insertAtCursor,
                    text: "迟到",
                    expectedContextFingerprint: nil,
                    requiresConfirmation: false
                )
            ),
            token: token
        ),
        .cancelled
    )
}

func testInvalidSessionCannotCreateOrConsumeIPC() {
    let invalid = "not-a-uuid"
    XCTAssertFalse(
        DarwinBridge.writeDictationSettings(
            DictationSettings(
                language: "zh-CN",
                whisper: false,
                translateEnabled: false,
                translateTarget: "en-US",
                selectedText: nil,
                keyboardType: 0,
                session: invalid
            )
        )
    )
    XCTAssertNil(DarwinBridge.peekDictationSettings(expectedSession: invalid))
    XCTAssertNil(DarwinBridge.readAndConsumeDictationSettings(expectedSession: invalid))
    XCTAssertNil(DarwinBridge.readAndConsumeResult(expectedSession: invalid))
    XCTAssertFalse(DarwinBridge.cancelSession(invalid))
}
```

Add this exact notification-boundary test; no unscoped cancel notification is permitted:

```swift
func testCancelNotificationNameRequiresValidSessionToken() {
    let token = SessionToken()
    XCTAssertNotNil(
        DarwinBridge.sessionNotificationName(
            base: DarwinNotificationName.requestCancelDictation,
            session: token.rawValue
        )
    )
    XCTAssertNil(
        DarwinBridge.sessionNotificationName(
            base: DarwinNotificationName.requestCancelDictation,
            session: "not-a-uuid"
        )
    )
}
```

- [x] **Step 6: Run IPC and model suites**

Run:

```bash
xcodebuild test \
  -project VoType.xcodeproj \
  -scheme VoTypeTests \
  -destination "platform=iOS Simulator,id=$SIM_ID" \
  CODE_SIGNING_ALLOWED=NO \
  CURRENT_PROJECT_VERSION="$PLAN_BUILD_NUMBER" \
  -only-testing:VoTypeTests/DictationSessionModelsTests \
  -only-testing:VoTypeTests/DictationConstantsTests \
  -derivedDataPath ./slice_a_test_build
```

Expected: PASS, including all pre-existing cancellation, receipt, stale-write, and 20-round IPC tests.

- [x] **Step 7: Commit the contract slice**

```bash
git add Shared/DictationSessionModels.swift Shared/DictationConstants.swift Shared/DarwinBridge.swift VoTypeTests/DictationSessionModelsTests.swift VoTypeTests/DictationConstantsTests.swift
git commit -m "feat: add typed dictation session contract"
```

---

### Task 2: Dependency Ports and Synchronous Audio Buffer Barrier

**Files:**
- Create: `VoiceInputApp/DictationSessionDependencies.swift`
- Create: `VoiceInputApp/DictationAudioBufferGate.swift`
- Create: `VoTypeTests/DictationAudioBufferGateTests.swift`

**Interfaces:**
- Consumes: request/event/terminal types from Task 1 and `AVAudioPCMBuffer` from AVFoundation.
- Produces: all injectable engine ports, `DictationSessionDeadlines`, `DictationAudioSystemEvent`, `DictationRecognitionUpdate`, `DictationSessionRunning`, and `DictationAudioBufferGate` used by Tasks 3-7.

- [x] **Step 1: Write the failing audio-path tests**

Create `VoTypeTests/DictationAudioBufferGateTests.swift`. Use a lock-protected fake sink and two semaphores so the test proves that `close` waits behind an in-flight append and rejects every later buffer:

```swift
import AVFoundation
import XCTest
@testable import VoiceInputApp

final class DictationAudioBufferGateTests: XCTestCase {
    func testCloseWaitsForInFlightAppendAndRejectsLaterBuffers() throws {
        let sink = BlockingSpeechSession()
        let gate = DictationAudioBufferGate(sink: sink)
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        let appendStarted = expectation(description: "append started")
        let closeReturned = DispatchSemaphore(value: 0)
        sink.onAppendStarted = { appendStarted.fulfill() }

        DispatchQueue.global().async { gate.append(buffer) }
        wait(for: [appendStarted], timeout: 1)
        DispatchQueue.global().async {
            gate.close(mode: .cancel)
            closeReturned.signal()
        }
        XCTAssertEqual(closeReturned.wait(timeout: .now() + 0.05), .timedOut)

        sink.releaseAppend.signal()
        XCTAssertEqual(closeReturned.wait(timeout: .now() + 1), .success)
        gate.append(buffer)

        XCTAssertEqual(sink.appendCount, 1)
        XCTAssertEqual(sink.cancelCount, 1)
        XCTAssertEqual(sink.endAudioCount, 0)
    }

    func testEndAudioRunsOnce() throws {
        let sink = BlockingSpeechSession(blocksAppend: false)
        let gate = DictationAudioBufferGate(sink: sink)
        gate.close(mode: .endAudio)
        gate.close(mode: .endAudio)
        XCTAssertEqual(sink.endAudioCount, 1)
        XCTAssertEqual(sink.cancelCount, 0)
    }
}
```

Define the test helper in the same file:

```swift
private final class BlockingSpeechSession: @unchecked Sendable, DictationSpeechSession {
    let releaseAppend = DispatchSemaphore(value: 0)
    var onAppendStarted: (() -> Void)?
    private let blocksAppend: Bool
    private let lock = NSLock()
    private var storedAppendCount = 0
    private var storedEndAudioCount = 0
    private var storedCancelCount = 0

    init(blocksAppend: Bool = true) {
        self.blocksAppend = blocksAppend
    }

    var appendCount: Int { locked { storedAppendCount } }
    var endAudioCount: Int { locked { storedEndAudioCount } }
    var cancelCount: Int { locked { storedCancelCount } }

    func append(_ buffer: AVAudioPCMBuffer) {
        locked { storedAppendCount += 1 }
        onAppendStarted?()
        if blocksAppend { releaseAppend.wait() }
    }

    func endAudio() { locked { storedEndAudioCount += 1 } }
    func cancel() { locked { storedCancelCount += 1 } }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
```

- [x] **Step 2: Run the gate tests and confirm the types are missing**

Run:

```bash
xcodebuild test -project VoType.xcodeproj -scheme VoTypeTests -destination "platform=iOS Simulator,id=$SIM_ID" CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION="$PLAN_BUILD_NUMBER" -only-testing:VoTypeTests/DictationAudioBufferGateTests -derivedDataPath ./slice_a_test_build
```

Expected: FAIL because `DictationAudioBufferGate`, `DictationSpeechSession`, and `DictationAudioBufferCloseMode` do not exist.

- [x] **Step 3: Define the narrow dependency ports**

Create `VoiceInputApp/DictationSessionDependencies.swift` with these signatures:

```swift
import AVFoundation
import Foundation

struct DictationSessionDeadlines: Equatable, Sendable {
    let start: TimeInterval
    let silence: TimeInterval
    let finalRecognition: TimeInterval
    let processing: TimeInterval
    let partialPublish: TimeInterval
    let foregroundClaim: TimeInterval

    static let production = DictationSessionDeadlines(
        start: 4.0,
        silence: 3.0,
        finalRecognition: 0.45,
        processing: 5.0,
        partialPublish: 0.20,
        foregroundClaim: 3.0
    )
}

enum DictationAudioSystemEvent: Equatable, Sendable {
    case interruptionBegan
    case inputRouteLost
    case mediaServicesReset
}

struct DictationRecognitionUpdate: Equatable, Sendable {
    let transcript: String
    let isFinal: Bool
}

protocol DictationPermissionResolving: Sendable {
    func authorize(
        policy: DictationAuthorizationPolicy
    ) async -> Result<Void, DictationFailure>
}

protocol DictationAudioSessionControlling: Sendable {
    func activate(whisper: Bool) throws
    func deactivate()
}

protocol DictationSpeechSession: AnyObject, Sendable {
    func append(_ buffer: AVAudioPCMBuffer)
    func endAudio()
    func cancel()
}

protocol DictationSpeechSessionCreating: Sendable {
    func makeSession(
        localeIdentifier: String,
        update: @escaping @Sendable (Result<DictationRecognitionUpdate, DictationFailure>) -> Void
    ) throws -> any DictationSpeechSession
}

protocol DictationAudioCaptureSession: AnyObject, Sendable {
    func start() throws
    func stop()
}

protocol DictationAudioCaptureCreating: Sendable {
    func makeSession(
        bufferHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) throws -> any DictationAudioCaptureSession
}

protocol DictationScheduledTask: Sendable {
    func cancel()
}

protocol DictationDeadlineScheduling: Sendable {
    func schedule(
        after interval: TimeInterval,
        action: @escaping @Sendable () -> Void
    ) -> any DictationScheduledTask
}

protocol DictationTextProcessing: Sendable {
    func process(
        transcript: String,
        snapshot: TextProcessingSnapshot
    ) async -> Result<EditPlan, DictationFailure>
}

protocol DictationSessionOutput: Sendable {
    func publishLive(
        _ envelope: DictationSessionEventEnvelope,
        request: DictationSessionRequest
    ) async

    func commit(
        _ terminal: DictationTerminal,
        token: SessionToken
    ) async -> DictationOutputCommitStatus
}

protocol DictationSessionRunning: Sendable {
    func start(
        _ request: DictationSessionRequest
    ) async -> AsyncStream<DictationSessionEventEnvelope>
    func stop(token: SessionToken) async
    func cancel(token: SessionToken) async
    func handleAudioSystemEvent(_ event: DictationAudioSystemEvent) async
}
```

- [x] **Step 4: Implement the direct audio gate**

Create `VoiceInputApp/DictationAudioBufferGate.swift`:

```swift
import AVFoundation
import Foundation

enum DictationAudioBufferCloseMode {
    case endAudio
    case cancel
}

final class DictationAudioBufferGate: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (any DictationSpeechSession)?

    init(sink: any DictationSpeechSession) {
        self.sink = sink
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        sink?.append(buffer)
    }

    func close(mode: DictationAudioBufferCloseMode) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = sink else { return }
        sink = nil
        switch mode {
        case .endAudio:
            current.endAudio()
        case .cancel:
            current.cancel()
        }
    }
}
```

The lock intentionally surrounds the synchronous `append` call: `close` cannot release or cancel the Speech request until the current append returns. No callback in this file may create a Swift `Task`.

- [x] **Step 5: Run the gate suite and a clean app build**

Run:

```bash
xcodebuild test -project VoType.xcodeproj -scheme VoTypeTests -destination "platform=iOS Simulator,id=$SIM_ID" CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION="$PLAN_BUILD_NUMBER" -only-testing:VoTypeTests/DictationAudioBufferGateTests -derivedDataPath ./slice_a_test_build
xcodebuild build -project VoType.xcodeproj -scheme VoiceInputApp -destination "platform=iOS Simulator,id=$SIM_ID" CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION="$PLAN_BUILD_NUMBER" -derivedDataPath ./slice_a_build
```

Expected: both commands PASS; Thread Sanitizer is not a substitute for the semaphore assertion.

- [x] **Step 6: Commit the dependency seam**

```bash
git add VoiceInputApp/DictationSessionDependencies.swift VoiceInputApp/DictationAudioBufferGate.swift VoTypeTests/DictationAudioBufferGateTests.swift
git commit -m "feat: add dictation dependency ports"
```

---

### Task 3: Implement the Engine Happy Path and Command Semantics

**Files:**
- Create: `VoiceInputApp/DictationSessionEngine.swift`
- Create: `VoTypeTests/DictationSessionTestDoubles.swift`
- Create: `VoTypeTests/DictationSessionEngineTests.swift`

**Interfaces:**
- Consumes: every port from Task 2 and session models from Task 1.
- Produces: actor `DictationSessionEngine` implementing `DictationSessionRunning`, with test-visible recognition callbacks routed by token and process-local generation.

- [ ] **Step 1: Build deterministic test doubles**

Create `VoTypeTests/DictationSessionTestDoubles.swift` with these capabilities:

```swift
import AVFoundation
import Foundation
import XCTest
@testable import VoiceInputApp

final class StubAudioSessionController: @unchecked Sendable, DictationAudioSessionControlling {
    var activationError: Error?
    private(set) var activatedWhisperValues: [Bool] = []
    private(set) var deactivateCount = 0
    private let lock = NSLock()

    func activate(whisper: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        if let activationError { throw activationError }
        activatedWhisperValues.append(whisper)
    }

    func deactivate() {
        lock.lock()
        deactivateCount += 1
        lock.unlock()
    }
}

final class ManualSpeechFactory: @unchecked Sendable, DictationSpeechSessionCreating {
    private var handlers: [@Sendable (Result<DictationRecognitionUpdate, DictationFailure>) -> Void] = []
    private var sessions: [RecordingSpeechSession] = []
    private let lock = NSLock()

    var sessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.count
    }

    func session(at index: Int) -> RecordingSpeechSession {
        lock.lock()
        defer { lock.unlock() }
        return sessions[index]
    }

    func makeSession(
        localeIdentifier: String,
        update: @escaping @Sendable (Result<DictationRecognitionUpdate, DictationFailure>) -> Void
    ) throws -> any DictationSpeechSession {
        let session = RecordingSpeechSession()
        lock.lock()
        handlers.append(update)
        sessions.append(session)
        lock.unlock()
        return session
    }

    func send(_ result: Result<DictationRecognitionUpdate, DictationFailure>, index: Int) {
        lock.lock()
        let handler = handlers[index]
        lock.unlock()
        handler(result)
    }
}

final class ManualAudioCaptureFactory: @unchecked Sendable, DictationAudioCaptureCreating {
    private var sessions: [RecordingAudioCaptureSession] = []
    private let lock = NSLock()

    var sessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.count
    }

    func session(at index: Int) -> RecordingAudioCaptureSession {
        lock.lock()
        defer { lock.unlock() }
        return sessions[index]
    }

    func makeSession(
        bufferHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) throws -> any DictationAudioCaptureSession {
        let session = RecordingAudioCaptureSession(bufferHandler: bufferHandler)
        lock.lock()
        sessions.append(session)
        lock.unlock()
        return session
    }
}

final class ManualDeadlineScheduler: @unchecked Sendable, DictationDeadlineScheduling {
    struct Pending {
        let interval: TimeInterval
        let action: @Sendable () -> Void
        let task: RecordingScheduledTask
    }
    private(set) var pending: [Pending] = []
    private let lock = NSLock()

    func schedule(
        after interval: TimeInterval,
        action: @escaping @Sendable () -> Void
    ) -> any DictationScheduledTask {
        let task = RecordingScheduledTask()
        lock.lock()
        pending.append(Pending(interval: interval, action: action, task: task))
        lock.unlock()
        return task
    }

    func fire(interval: TimeInterval) {
        lock.lock()
        let matches = pending.filter { $0.interval == interval && !$0.task.isCancelled }
        pending.removeAll { $0.interval == interval }
        lock.unlock()
        matches.forEach { $0.action() }
    }
}

actor RecordingTextProcessor: DictationTextProcessing {
    var result: Result<EditPlan, DictationFailure>
    private(set) var calls: [(String, TextProcessingSnapshot)] = []

    init(result: Result<EditPlan, DictationFailure>) { self.result = result }

    func process(
        transcript: String,
        snapshot: TextProcessingSnapshot
    ) async -> Result<EditPlan, DictationFailure> {
        calls.append((transcript, snapshot))
        return result
    }
}

actor RecordingSessionOutput: DictationSessionOutput {
    var commitStatus: DictationOutputCommitStatus = .written
    private(set) var liveEvents: [DictationSessionEventEnvelope] = []
    private(set) var terminals: [(DictationTerminal, SessionToken)] = []

    func publishLive(
        _ envelope: DictationSessionEventEnvelope,
        request: DictationSessionRequest
    ) async {
        liveEvents.append(envelope)
    }

    func commit(
        _ terminal: DictationTerminal,
        token: SessionToken
    ) async -> DictationOutputCommitStatus {
        terminals.append((terminal, token))
        return commitStatus
    }
}
```

Add the remaining concrete fakes and collection helper to the same file:

```swift
final class RecordingSpeechSession: @unchecked Sendable, DictationSpeechSession {
    private let lock = NSLock()
    private var storedAppendCount = 0
    private var storedEndAudioCount = 0
    private var storedCancelCount = 0

    var appendCount: Int { locked { storedAppendCount } }
    var endAudioCount: Int { locked { storedEndAudioCount } }
    var cancelCount: Int { locked { storedCancelCount } }

    func append(_ buffer: AVAudioPCMBuffer) { locked { storedAppendCount += 1 } }
    func endAudio() { locked { storedEndAudioCount += 1 } }
    func cancel() { locked { storedCancelCount += 1 } }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class RecordingAudioCaptureSession: @unchecked Sendable, DictationAudioCaptureSession {
    private let bufferHandler: @Sendable (AVAudioPCMBuffer) -> Void
    private let lock = NSLock()
    private var storedStartCount = 0
    private var storedStopCount = 0

    init(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.bufferHandler = bufferHandler
    }

    var startCount: Int { locked { storedStartCount } }
    var stopCount: Int { locked { storedStopCount } }

    func start() throws { locked { storedStartCount += 1 } }
    func stop() { locked { storedStopCount += 1 } }
    func deliver(_ buffer: AVAudioPCMBuffer) { bufferHandler(buffer) }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class RecordingScheduledTask: @unchecked Sendable, DictationScheduledTask {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

actor ManualPermissionResolver: DictationPermissionResolving {
    private let suspends: Bool
    private var continuation: CheckedContinuation<Result<Void, DictationFailure>, Never>?
    private(set) var policies: [DictationAuthorizationPolicy] = []
    var result: Result<Void, DictationFailure> = .success(())

    init(suspends: Bool = false) {
        self.suspends = suspends
    }

    func authorize(
        policy: DictationAuthorizationPolicy
    ) async -> Result<Void, DictationFailure> {
        policies.append(policy)
        guard suspends else { return result }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resume(with result: Result<Void, DictationFailure>) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

func collectEvents(
    _ stream: AsyncStream<DictationSessionEventEnvelope>
) async -> [DictationSessionEventEnvelope] {
    var events: [DictationSessionEventEnvelope] = []
    for await event in stream { events.append(event) }
    return events
}

final class EngineHarness {
    let deadlines = DictationSessionDeadlines(
        start: 4,
        silence: 3,
        finalRecognition: 0.45,
        processing: 5,
        partialPublish: 0.20,
        foregroundClaim: 3
    )
    let completedPlan: EditPlan
    let permissions: ManualPermissionResolver
    let audioSession = StubAudioSessionController()
    let speech = ManualSpeechFactory()
    let audio = ManualAudioCaptureFactory()
    let scheduler = ManualDeadlineScheduler()
    let processor: RecordingTextProcessor
    let output = RecordingSessionOutput()
    let engine: DictationSessionEngine

    init(permissionSuspended: Bool = false) {
        let plan = EditPlan(
            intent: .dictate,
            operation: .insertAtCursor,
            text: "处理后文本",
            expectedContextFingerprint: nil,
            requiresConfirmation: false
        )
        completedPlan = plan
        permissions = ManualPermissionResolver(suspends: permissionSuspended)
        processor = RecordingTextProcessor(result: .success(plan))
        engine = DictationSessionEngine(
            permissions: permissions,
            audioSession: audioSession,
            speechFactory: speech,
            audioFactory: audio,
            scheduler: scheduler,
            processor: processor,
            output: output,
            deadlines: deadlines
        )
    }

    func makeRequest() -> DictationSessionRequest {
        DictationSessionRequest(
            token: SessionToken(),
            entryPoint: .foreground,
            authorizationPolicy: .requestIfNeeded,
            whisper: false,
            processing: TextProcessingSnapshot(
                selectedText: nil,
                keyboardType: 0,
                language: "zh-CN",
                translateEnabled: false,
                translateTarget: "en-US",
                voiceEditEnabled: true,
                livePreviewEnabled: true,
                expectedContextFingerprint: nil
            )
        )
    }

    func waitForSpeechSessionCount(_ expected: Int) async {
        for _ in 0..<1_000 {
            if speech.sessionCount == expected { return }
            await Task.yield()
        }
        XCTFail("Expected \(expected) Speech sessions, got \(speech.sessionCount)")
    }
}
```

None of these fakes may call Apple permission, Speech, or audio APIs.

- [ ] **Step 2: Write failing lifecycle and command tests**

Create `VoTypeTests/DictationSessionEngineTests.swift` with a shared `makeRequest` helper and these assertions:

```swift
func testHappyPathEmitsOrderedEventsAndCommitsBeforeCompleted() async throws {
    let harness = EngineHarness()
    let request = harness.makeRequest()
    let stream = await harness.engine.start(request)
    let events = Task { await collectEvents(stream) }

    await harness.waitForSpeechSessionCount(1)
    harness.speech.send(.success(.init(transcript: "你好", isFinal: false)), index: 0)
    harness.speech.send(.success(.init(transcript: "你好世界", isFinal: true)), index: 0)

    let received = await events.value
    XCTAssertEqual(received.map(\.sequence), Array(1...UInt64(received.count)))
    XCTAssertEqual(received.map(\.event), [
        .authorizing,
        .preparing,
        .listening(partial: ""),
        .listening(partial: "你好"),
        .processing,
        .completed(harness.completedPlan)
    ])
    let terminalCount = await harness.output.terminals.count
    XCTAssertEqual(terminalCount, 1)
}

func testStopWhileListeningEndsAudioAndWaitsForFinalRecognition() async throws {
    let harness = EngineHarness()
    let request = harness.makeRequest()
    let stream = await harness.engine.start(request)
    let events = Task { await collectEvents(stream) }
    await harness.waitForSpeechSessionCount(1)

    await harness.engine.stop(token: request.token)
    XCTAssertEqual(harness.speech.session(at: 0).endAudioCount, 1)
    harness.speech.send(.success(.init(transcript: "最终文本", isFinal: true)), index: 0)

    let received = await events.value
    XCTAssertEqual(received.last?.event, .completed(harness.completedPlan))
}

func testStopWhileAuthorizingCancelsAndStopWhileProcessingIsNoOp() async throws {
    let harness = EngineHarness(permissionSuspended: true)
    let first = harness.makeRequest()
    let firstEvents = Task { await collectEvents(await harness.engine.start(first)) }
    await harness.engine.stop(token: first.token)
    let firstReceived = await firstEvents.value
    XCTAssertEqual(firstReceived.last?.event, .cancelled)
    await harness.permissions.resume(with: .success(()))

    let processingHarness = EngineHarness()
    let second = processingHarness.makeRequest()
    let secondEvents = Task {
        await collectEvents(await processingHarness.engine.start(second))
    }
    await processingHarness.waitForSpeechSessionCount(1)
    await processingHarness.engine.stop(token: second.token)
    await processingHarness.engine.stop(token: second.token)
    processingHarness.speech.send(
        .success(.init(transcript: "最终文本", isFinal: true)),
        index: 0
    )
    let secondReceived = await secondEvents.value
    XCTAssertEqual(secondReceived.filter(\.event.isTerminal).count, 1)
}

func testCancelDiscardsPartialAndCommitsCancelledOnce() async throws {
    let harness = EngineHarness()
    let request = harness.makeRequest()
    let events = Task { await collectEvents(await harness.engine.start(request)) }
    await harness.waitForSpeechSessionCount(1)
    harness.speech.send(.success(.init(transcript: "不会提交", isFinal: false)), index: 0)
    await harness.engine.cancel(token: request.token)
    await harness.engine.cancel(token: request.token)

    let received = await events.value
    let terminals = await harness.output.terminals.map(\.0)
    XCTAssertEqual(received.last?.event, .cancelled)
    XCTAssertEqual(terminals, [.cancelled])
}

private extension DictationSessionEvent {
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .authorizing, .preparing, .listening, .processing:
            return false
        }
    }
}
```

Before RED, extend the same test-only harness with explicitly gated output calls and add these ownership regressions:

1. `testThreeStartsKeepLatestOwnerWhileOlderCommitsAreSuspended`: admit A, B, then C while A/B terminal commits are gated; release the older commits in reverse order. C alone may complete as current; A/B each finish with one cancelled terminal; each token reaches output commit at most once.
2. `testSupersessionDuringAuthorizingPublicationSkipsOldPermissionWork`: gate A's authorizing publication, admit B, then release A. A must not start a permission request or create Speech/audio resources after resumption. B stays current and A's stream closes once.
3. `testSupersessionClosesOldResourcesBeforeNewCaptureStarts`: make A listening, admit B, and assert the operation journal closes A's capture/gate/Speech/audio session before B starts capture, with A's Speech `cancelCount == 1`; deliver A's late callbacks and assert no B stream/output/state change. Task 4 adds deadline callbacks to the same guarantee.

All readiness waits and stream collection must have explicit finite deadlines and cleanup; an incorrect actor must fail the test rather than hang the CI job. Do not assume a spawned `Task` has started, or use a fixed number of `Task.yield` calls as synchronization. Keep gated-output controls in test doubles only. These tests enforce the existing single-owner/exactly-one-terminal specification; they do not change the public runner interface.

- [ ] **Step 3: Run the engine suite and observe the missing actor**

Run:

```bash
xcodebuild test -project VoType.xcodeproj -scheme VoTypeTests -destination "platform=iOS Simulator,id=$SIM_ID" CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION="$PLAN_BUILD_NUMBER" -only-testing:VoTypeTests/DictationSessionEngineTests -derivedDataPath ./slice_a_test_build
```

Expected: FAIL because `DictationSessionEngine` and `EngineHarness` do not exist.

- [ ] **Step 4: Implement the actor state and ordered emission**

Create `VoiceInputApp/DictationSessionEngine.swift`. The active record must contain only one token/generation, phase, immutable request, event sequence, latest transcript, resource ports, deadlines, and stream continuation:

```swift
import Foundation

actor DictationSessionEngine: DictationSessionRunning {
    private enum Phase: Equatable {
        case authorizing
        case preparing
        case listening
        case processing
    }

    private struct ActiveSession {
        let request: DictationSessionRequest
        let generation: UInt64
        var phase: Phase
        var nextSequence: UInt64
        var transcript: String
        var pendingPartial: String?
        var continuation: AsyncStream<DictationSessionEventEnvelope>.Continuation
        var speech: (any DictationSpeechSession)?
        var audioCapture: (any DictationAudioCaptureSession)?
        var bufferGate: DictationAudioBufferGate?
        var startDeadline: (any DictationScheduledTask)?
        var silenceDeadline: (any DictationScheduledTask)?
        var finalDeadline: (any DictationScheduledTask)?
        var processingDeadline: (any DictationScheduledTask)?
        var partialDeadline: (any DictationScheduledTask)?
        var hasStartedTextProcessing: Bool
        var finishStarted: Bool
    }

    private let permissions: any DictationPermissionResolving
    private let audioSession: any DictationAudioSessionControlling
    private let speechFactory: any DictationSpeechSessionCreating
    private let audioFactory: any DictationAudioCaptureCreating
    private let scheduler: any DictationDeadlineScheduling
    private let processor: any DictationTextProcessing
    private let output: any DictationSessionOutput
    private let deadlines: DictationSessionDeadlines
    private var nextGeneration: UInt64 = 0
    private var active: ActiveSession?

    init(
        permissions: any DictationPermissionResolving,
        audioSession: any DictationAudioSessionControlling,
        speechFactory: any DictationSpeechSessionCreating,
        audioFactory: any DictationAudioCaptureCreating,
        scheduler: any DictationDeadlineScheduling,
        processor: any DictationTextProcessing,
        output: any DictationSessionOutput,
        deadlines: DictationSessionDeadlines = .production
    ) {
        self.permissions = permissions
        self.audioSession = audioSession
        self.speechFactory = speechFactory
        self.audioFactory = audioFactory
        self.scheduler = scheduler
        self.processor = processor
        self.output = output
        self.deadlines = deadlines
    }
}
```

`start` is linearized at actor admission: “latest” means the latest call admitted by the actor, not the wall-clock order of concurrent callers. Before its first suspension, synchronously reserve/close any superseded active session, install the incoming generation and stream, and yield `.authorizing` at sequence 1. Complete older streams only through their frozen reservations. Use the reservation implementation in Step 5 now; do not defer this ownership protection to Task 4. Every callback captures both the immutable token and generation:

```swift
func start(
    _ request: DictationSessionRequest
) async -> AsyncStream<DictationSessionEventEnvelope> {
    if let previous = active,
       let reservation = reserveFinish(
           .cancelled,
           token: previous.request.token,
           generation: previous.generation
       ) {
        Task { await self.completeFinish(reservation) }
    }

    nextGeneration &+= 1
    let generation = nextGeneration
    var continuation: AsyncStream<DictationSessionEventEnvelope>.Continuation!
    let stream = AsyncStream<DictationSessionEventEnvelope> { continuation = $0 }
    active = ActiveSession(
        request: request,
        generation: generation,
        phase: .authorizing,
        nextSequence: 1,
        transcript: "",
        pendingPartial: nil,
        continuation: continuation,
        speech: nil,
        audioCapture: nil,
        bufferGate: nil,
        startDeadline: nil,
        silenceDeadline: nil,
        finalDeadline: nil,
        processingDeadline: nil,
        partialDeadline: nil,
        hasStartedTextProcessing: false,
        finishStarted: false
    )
    await emit(.authorizing, token: request.token, generation: generation)

    Task { [permissions] in
        guard let current = self.matching(token: request.token, generation: generation),
              current.phase == .authorizing,
              !current.finishStarted else { return }
        let result = await permissions.authorize(policy: request.authorizationPolicy)
        await self.authorizationResolved(result, token: request.token, generation: generation)
    }
    return stream
}
```

`authorizationResolved` checks token/generation/phase, emits `.preparing`, activates the audio session, constructs Speech, then creates capture with the direct closure `gate.append(buffer)`. The Speech callback alone creates a task to cross into the actor:

```swift
let speech = try speechFactory.makeSession(
    localeIdentifier: request.processing.language
) { [weak self] result in
    Task {
        await self?.recognitionUpdated(result, token: token, generation: generation)
    }
}
let gate = DictationAudioBufferGate(sink: speech)
let capture = try audioFactory.makeSession { buffer in
    gate.append(buffer)
}
try capture.start()
```

Use this control flow to store resources only after every generation check, emit `.listening(partial: "")`, and reject stale callbacks:

```swift
private func authorizationResolved(
    _ result: Result<Void, DictationFailure>,
    token: SessionToken,
    generation: UInt64
) async {
    guard var current = matching(token: token, generation: generation),
          current.phase == .authorizing else { return }
    guard case .success = result else {
        if case .failure(let failure) = result {
            await finish(.failed(failure), token: token, generation: generation)
        }
        return
    }

    current.phase = .preparing
    active = current
    await emit(.preparing, token: token, generation: generation)
    guard let prepared = matching(token: token, generation: generation),
          prepared.phase == .preparing,
          !prepared.finishStarted else { return }

    do {
        try audioSession.activate(whisper: prepared.request.whisper)
    } catch {
        await finish(.failed(.audioSession), token: token, generation: generation)
        return
    }

    let speech: any DictationSpeechSession
    do {
        speech = try speechFactory.makeSession(
            localeIdentifier: prepared.request.processing.language
        ) { [weak self] result in
            Task {
                await self?.recognitionUpdated(
                    result,
                    token: token,
                    generation: generation
                )
            }
        }
    } catch {
        await finish(.failed(.recognitionUnavailable), token: token, generation: generation)
        return
    }

    let gate = DictationAudioBufferGate(sink: speech)
    let capture: any DictationAudioCaptureSession
    do {
        capture = try audioFactory.makeSession { buffer in gate.append(buffer) }
        try capture.start()
    } catch {
        gate.close(mode: .cancel)
        await finish(.failed(.audioCapture), token: token, generation: generation)
        return
    }

    guard var listening = matching(token: token, generation: generation),
          listening.phase == .preparing else {
        capture.stop()
        gate.close(mode: .cancel)
        audioSession.deactivate()
        return
    }
    listening.speech = speech
    listening.audioCapture = capture
    listening.bufferGate = gate
    listening.phase = .listening
    active = listening
    await emit(.listening(partial: ""), token: token, generation: generation)
}

private func recognitionUpdated(
    _ result: Result<DictationRecognitionUpdate, DictationFailure>,
    token: SessionToken,
    generation: UInt64
) async {
    guard var current = matching(token: token, generation: generation),
          current.phase == .listening || current.phase == .processing else { return }
    switch result {
    case .failure(let failure):
        await finish(.failed(failure), token: token, generation: generation)
    case .success(let update):
        current.transcript = update.transcript
        active = current
        if update.isFinal {
            if current.phase == .listening {
                await beginProcessing(token: token, generation: generation)
            }
            await startTextProcessing(token: token, generation: generation)
        } else if current.phase == .listening {
            await emit(.listening(partial: update.transcript), token: token, generation: generation)
        }
    }
}
```

Implement command dispatch with this exact phase switch:

```swift
func stop(token: SessionToken) async {
    guard let current = active, current.request.token == token else { return }
    switch current.phase {
    case .authorizing, .preparing:
        await finish(.cancelled, token: token, generation: current.generation)
    case .listening:
        await beginProcessing(token: token, generation: current.generation)
    case .processing:
        return
    }
}

func cancel(token: SessionToken) async {
    guard let current = active, current.request.token == token else { return }
    await finish(.cancelled, token: token, generation: current.generation)
}

func handleAudioSystemEvent(_ event: DictationAudioSystemEvent) async {
    guard let current = active else { return }
    let failure: DictationFailure
    switch event {
    case .interruptionBegan: failure = .interrupted
    case .inputRouteLost: failure = .inputRouteLost
    case .mediaServicesReset: failure = .mediaServicesReset
    }
    await finish(.failed(failure), token: current.request.token, generation: current.generation)
}
```

Do not add a pause state.

- [ ] **Step 5: Implement processing and the single terminal path**

When final recognition arrives, or when Task 4's final deadline fires, synchronously stop capture, barrier-close the gate with `.endAudio`, deactivate the audio session, emit `.processing`, and run the processor once:

```swift
private func beginProcessing(token: SessionToken, generation: UInt64) async {
    guard var current = matching(token: token, generation: generation),
          current.phase == .listening else { return }
    current.phase = .processing
    current.audioCapture?.stop()
    current.bufferGate?.close(mode: .endAudio)
    current.audioCapture = nil
    current.bufferGate = nil
    active = current
    audioSession.deactivate()
    await emit(.processing, token: token, generation: generation)
}

private func startTextProcessing(token: SessionToken, generation: UInt64) async {
    guard var current = matching(token: token, generation: generation),
          current.phase == .processing,
          !current.hasStartedTextProcessing else { return }
    let transcript = current.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !transcript.isEmpty else {
        await finish(.failed(.noSpeech), token: token, generation: generation)
        return
    }
    current.hasStartedTextProcessing = true
    let snapshot = current.request.processing
    active = current
    Task { [processor] in
        let result = await processor.process(transcript: transcript, snapshot: snapshot)
        await self.processingFinished(result, token: token, generation: generation)
    }
}

private func processingFinished(
    _ result: Result<EditPlan, DictationFailure>,
    token: SessionToken,
    generation: UInt64
) async {
    guard matching(token: token, generation: generation) != nil else { return }
    switch result {
    case .success(let plan):
        await finish(.completed(plan), token: token, generation: generation)
    case .failure(let failure):
        await finish(.failed(failure), token: token, generation: generation)
    }
}
```

`finish` must reserve and detach the active record before its first suspension. Its async completion uses only the frozen reservation and never reads or writes a later `active` record. This is required in Task 3, not an unsafe intermediate state to replace in Task 4:

```swift
private struct FinishReservation {
    let token: SessionToken
    let terminal: DictationTerminal
    let sequence: UInt64
    let continuation: AsyncStream<DictationSessionEventEnvelope>.Continuation
}

private func reserveFinish(
    _ terminal: DictationTerminal,
    token: SessionToken,
    generation: UInt64
) -> FinishReservation? {
    guard var current = matching(token: token, generation: generation),
          !current.finishStarted else { return nil }
    current.finishStarted = true
    cancelDeadlines(in: &current)
    current.audioCapture?.stop()
    if let gate = current.bufferGate {
        gate.close(mode: terminal.bufferCloseMode)
    } else {
        current.speech?.cancel()
    }
    audioSession.deactivate()
    active = nil
    return FinishReservation(
        token: token,
        terminal: terminal,
        sequence: current.nextSequence,
        continuation: current.continuation
    )
}

private func finish(
    _ terminal: DictationTerminal,
    token: SessionToken,
    generation: UInt64
) async {
    guard let reservation = reserveFinish(
        terminal,
        token: token,
        generation: generation
    ) else { return }
    await completeFinish(reservation)
}

private func completeFinish(_ reservation: FinishReservation) async {
    let commitStatus = await output.commit(reservation.terminal, token: reservation.token)
    let delivered: DictationSessionEvent
    switch commitStatus {
    case .written:
        delivered = reservation.terminal.event
    case .cancelled:
        delivered = .cancelled
    case .alreadyTerminal:
        delivered = reservation.terminal.event
    case .ioFailure:
        delivered = .failed(.outputPersistence)
    }
    reservation.continuation.yield(
        DictationSessionEventEnvelope(
            token: reservation.token,
            sequence: reservation.sequence,
            event: delivered
        )
    )
    reservation.continuation.finish()
}

private func matching(
    token: SessionToken,
    generation: UInt64
) -> ActiveSession? {
    guard let current = active,
          current.request.token == token,
          current.generation == generation else { return nil }
    return current
}

private func emit(
    _ event: DictationSessionEvent,
    token: SessionToken,
    generation: UInt64
) async {
    guard var current = matching(token: token, generation: generation) else { return }
    let envelope = DictationSessionEventEnvelope(
        token: token,
        sequence: current.nextSequence,
        event: event
    )
    current.nextSequence &+= 1
    let continuation = current.continuation
    active = current
    continuation.yield(envelope)

    switch event {
    case .authorizing, .preparing, .listening, .processing:
        await output.publishLive(envelope, request: current.request)
        guard matching(token: token, generation: generation) != nil else { return }
    case .completed, .failed, .cancelled:
        return
    }
}

private func cancelDeadlines(in session: inout ActiveSession) {
    session.startDeadline?.cancel()
    session.silenceDeadline?.cancel()
    session.finalDeadline?.cancel()
    session.processingDeadline?.cancel()
    session.partialDeadline?.cancel()
    session.startDeadline = nil
    session.silenceDeadline = nil
    session.finalDeadline = nil
    session.processingDeadline = nil
    session.partialDeadline = nil
}
```

Add the terminal mapping in the same file:

```swift
private extension DictationTerminal {
    var event: DictationSessionEvent {
        switch self {
        case .completed(let plan): return .completed(plan)
        case .failed(let failure): return .failed(failure)
        case .cancelled: return .cancelled
        }
    }

    var bufferCloseMode: DictationAudioBufferCloseMode {
        switch self {
        case .completed:
            return .endAudio
        case .failed, .cancelled:
            return .cancel
        }
    }
}
```

- [ ] **Step 6: Run the lifecycle suite**

Run:

```bash
xcodebuild test -project VoType.xcodeproj -scheme VoTypeTests -destination "platform=iOS Simulator,id=$SIM_ID" CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION="$PLAN_BUILD_NUMBER" -only-testing:VoTypeTests/DictationSessionEngineTests -only-testing:VoTypeTests/DictationAudioBufferGateTests -derivedDataPath ./slice_a_test_build
```

Expected: PASS with ordered sequence values, exactly one terminal, and no second gate close.

- [ ] **Step 7: Commit the first engine implementation**

```bash
git add VoiceInputApp/DictationSessionEngine.swift VoTypeTests/DictationSessionTestDoubles.swift VoTypeTests/DictationSessionEngineTests.swift
git commit -m "feat: add unified dictation session engine"
```

---

### Task 4: Harden Deadlines, Stale Callbacks, Races, and Reuse

**Files:**
- Modify: `VoiceInputApp/DictationSessionEngine.swift`
- Modify: `VoTypeTests/DictationSessionTestDoubles.swift`
- Modify: `VoTypeTests/DictationSessionEngineTests.swift`

**Interfaces:**
- Consumes: the engine and manual scheduler from Task 3.
- Produces: deterministic start/silence/final-recognition/processing deadlines, latest-partial coalescing, stale-generation rejection, and exactly-one behavior under concurrent callbacks.

- [ ] **Step 1: Add failing deadline and partial-coalescing tests**

Add these cases to `DictationSessionEngineTests`:

```swift
func testStartDeadlineFailsOnceBeforeListening() async throws {
    let harness = EngineHarness(permissionSuspended: true)
    let request = harness.makeRequest()
    let events = Task { await collectEvents(await harness.engine.start(request)) }
    harness.scheduler.fire(interval: harness.deadlines.start)
    harness.scheduler.fire(interval: harness.deadlines.start)
    let received = await events.value
    let terminalCount = await harness.output.terminals.count
    XCTAssertEqual(received.suffix(1).map(\.event), [.failed(.startTimeout)])
    XCTAssertEqual(terminalCount, 1)
}

func testFinalRecognitionDeadlineProcessesLatestPartial() async throws {
    let harness = EngineHarness()
    let request = harness.makeRequest()
    let events = Task { await collectEvents(await harness.engine.start(request)) }
    await harness.waitForSpeechSessionCount(1)
    harness.speech.send(.success(.init(transcript: "最新部分", isFinal: false)), index: 0)
    await harness.engine.stop(token: request.token)
    harness.scheduler.fire(interval: harness.deadlines.finalRecognition)
    let received = await events.value
    let transcripts = await harness.processor.calls.map(\.0)
    XCTAssertEqual(received.last?.event, .completed(harness.completedPlan))
    XCTAssertEqual(transcripts, ["最新部分"])
}

func testPartialBurstPublishesOnlyLatestValuePerWindow() async throws {
    let harness = EngineHarness()
    let request = harness.makeRequest()
    let events = Task { await collectEvents(await harness.engine.start(request)) }
    await harness.waitForSpeechSessionCount(1)
    for index in 0..<500 {
        harness.speech.send(.success(.init(transcript: "部分\(index)", isFinal: false)), index: 0)
    }
    harness.scheduler.fire(interval: harness.deadlines.partialPublish)
    await harness.engine.cancel(token: request.token)
    let listening = (await events.value).compactMap { envelope -> String? in
        guard case .listening(let partial) = envelope.event, !partial.isEmpty else { return nil }
        return partial
    }
    XCTAssertEqual(listening, ["部分499"])
}
```

- [ ] **Step 2: Add failing stale-generation and concurrent-terminal tests**

Add these cases:

```swift
func testSupersededGenerationCannotAffectNewSession() async throws {
    let harness = EngineHarness()
    let first = harness.makeRequest()
    let firstEvents = Task { await collectEvents(await harness.engine.start(first)) }
    await harness.waitForSpeechSessionCount(1)

    let second = harness.makeRequest()
    let secondEvents = Task { await collectEvents(await harness.engine.start(second)) }
    await harness.waitForSpeechSessionCount(2)
    harness.speech.send(.success(.init(transcript: "旧回调", isFinal: true)), index: 0)
    harness.speech.send(.success(.init(transcript: "新结果", isFinal: true)), index: 1)

    let firstReceived = await firstEvents.value
    let secondReceived = await secondEvents.value
    let processedTranscripts = await harness.processor.calls.map(\.0)
    XCTAssertEqual(firstReceived.last?.event, .cancelled)
    XCTAssertEqual(secondReceived.last?.event, .completed(harness.completedPlan))
    XCTAssertFalse(processedTranscripts.contains("旧回调"))
}

func testConcurrentFinalCancelInterruptionAndTimeoutCommitOnce() async throws {
    for _ in 0..<100 {
        let harness = EngineHarness()
        let request = harness.makeRequest()
        let events = Task { await collectEvents(await harness.engine.start(request)) }
        await harness.waitForSpeechSessionCount(1)

        await harness.engine.stop(token: request.token)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                harness.speech.send(.success(.init(transcript: "竞争结果", isFinal: true)), index: 0)
            }
            group.addTask { await harness.engine.cancel(token: request.token) }
            group.addTask { await harness.engine.handleAudioSystemEvent(.interruptionBegan) }
            group.addTask { harness.scheduler.fire(interval: harness.deadlines.finalRecognition) }
        }

        let received = await events.value
        let terminalCount = await harness.output.terminals.count
        XCTAssertEqual(received.filter(\.event.isTerminal).count, 1)
        XCTAssertEqual(terminalCount, 1)
    }
}

func testEachAudioSystemFailureTerminatesOnceWithoutResume() async throws {
    let cases: [(DictationAudioSystemEvent, DictationFailure)] = [
        (.interruptionBegan, .interrupted),
        (.inputRouteLost, .inputRouteLost),
        (.mediaServicesReset, .mediaServicesReset)
    ]
    for (systemEvent, expectedFailure) in cases {
        let harness = EngineHarness()
        let request = harness.makeRequest()
        let events = Task { await collectEvents(await harness.engine.start(request)) }
        await harness.waitForSpeechSessionCount(1)
        await harness.engine.handleAudioSystemEvent(systemEvent)
        await harness.engine.handleAudioSystemEvent(systemEvent)
        let received = await events.value
        let terminalCount = await harness.output.terminals.count
        XCTAssertEqual(received.suffix(1).map(\.event), [.failed(expectedFailure)])
        XCTAssertEqual(terminalCount, 1)
    }
}

func testOutputFailureNeverEmitsCompleted() async throws {
    let harness = EngineHarness()
    await harness.output.setCommitStatus(.ioFailure)
    let request = harness.makeRequest()
    let events = Task { await collectEvents(await harness.engine.start(request)) }
    await harness.waitForSpeechSessionCount(1)
    harness.speech.send(.success(.init(transcript: "结果", isFinal: true)), index: 0)
    let received = await events.value
    XCTAssertEqual(received.last?.event, .failed(.outputPersistence))
    XCTAssertFalse(received.contains { envelope in
        if case .completed = envelope.event { return true }
        return false
    })
    let terminalCount = await harness.output.terminals.count
    XCTAssertEqual(terminalCount, 1)
}
```

- [ ] **Step 3: Run the focused tests and observe the missing deadline/race protection**

Run each new method with `-only-testing`. Expected: at least one FAIL because the manual deadlines, coalescing, or concurrent finish arbitration is not yet implemented.

- [ ] **Step 4: Implement all deadlines with captured identity**

Schedule every closure with both token and generation. The closure may create one task to enter the actor; audio buffers remain on the direct gate path:

```swift
private func schedule(
    _ interval: TimeInterval,
    token: SessionToken,
    generation: UInt64,
    action: @escaping @Sendable (DictationSessionEngine) async -> Void
) -> any DictationScheduledTask {
    scheduler.schedule(after: interval) { [weak self] in
        guard let self else { return }
        Task { await action(self) }
    }
}
```

Use the exact failure rules:

- start deadline while authorizing/preparing → `.failed(.startTimeout)`;
- silence deadline after a nonempty partial → enter processing exactly as `stop` does;
- final-recognition deadline while processing awaits Speech final → process the latest nonempty partial, otherwise `.failed(.noSpeech)`;
- processing deadline → `.failed(.processingTimeout)`;
- any deadline from a different token/generation → no state change and no output.

Cancel and replace the silence deadline on each newer partial. Replace the Task 3 non-final branch with these helpers so only `pendingPartial` is retained and one latest value is emitted per publish window:

```swift
private func receivePartial(
    _ transcript: String,
    token: SessionToken,
    generation: UInt64
) {
    guard var current = matching(token: token, generation: generation),
          current.phase == .listening else { return }
    current.transcript = transcript
    current.pendingPartial = transcript
    current.silenceDeadline?.cancel()
    current.silenceDeadline = schedule(
        deadlines.silence,
        token: token,
        generation: generation
    ) { engine in
        await engine.silenceExpired(token: token, generation: generation)
    }
    if current.partialDeadline == nil {
        current.partialDeadline = schedule(
            deadlines.partialPublish,
            token: token,
            generation: generation
        ) { engine in
            await engine.publishPendingPartial(token: token, generation: generation)
        }
    }
    active = current
}

private func publishPendingPartial(token: SessionToken, generation: UInt64) async {
    guard var current = matching(token: token, generation: generation),
          current.phase == .listening,
          let partial = current.pendingPartial else { return }
    current.pendingPartial = nil
    current.partialDeadline = nil
    active = current
    await emit(.listening(partial: partial), token: token, generation: generation)
}

private func startExpired(token: SessionToken, generation: UInt64) async {
    guard let current = matching(token: token, generation: generation),
          current.phase == .authorizing || current.phase == .preparing else { return }
    await finish(.failed(.startTimeout), token: token, generation: generation)
}

private func silenceExpired(token: SessionToken, generation: UInt64) async {
    guard let current = matching(token: token, generation: generation),
          current.phase == .listening,
          !current.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    await beginProcessing(token: token, generation: generation)
}

private func finalRecognitionExpired(token: SessionToken, generation: UInt64) async {
    guard let current = matching(token: token, generation: generation),
          current.phase == .processing,
          !current.hasStartedTextProcessing else { return }
    if current.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        await finish(.failed(.noSpeech), token: token, generation: generation)
    } else {
        await startTextProcessing(token: token, generation: generation)
    }
}

private func processingExpired(token: SessionToken, generation: UInt64) async {
    guard let current = matching(token: token, generation: generation),
          current.phase == .processing,
          current.hasStartedTextProcessing else { return }
    await finish(.failed(.processingTimeout), token: token, generation: generation)
}
```

Schedule `startDeadline` immediately after installing the active record; cancel it only after capture reaches listening. In `beginProcessing`, call `publishPendingPartial` before changing phase, then re-fetch and recheck token/generation/listening phase before scheduling `finalDeadline`; never restore a pre-await record. In `startTextProcessing`, cancel `finalDeadline` and schedule `processingDeadline`. `processingFinished` cancels `processingDeadline` before calling `finish`. Every assignment is written back to `active` before an awaited call, and ownership is revalidated after every suspension. The partial publication timer is one pending window, not a debounce timer reset by every partial.

- [ ] **Step 5: Make terminal arbitration re-entrancy safe**

Retain Task 3's synchronous reservation plus async frozen completion and harden it with concurrent callback tests. The reservation sets `finishStarted`, detaches resources/deadlines, and freezes the terminal envelope before any `await`. All later finish attempts return before calling the output port. After awaiting commit, complete only the captured stream without reading or writing `active`. Output `.ioFailure` yields only in-memory `.failed(.outputPersistence)` and creates no fabricated success result. Add this actor method to `RecordingSessionOutput` so the test changes commit behavior without unsafe cross-actor mutation:

```swift
func setCommitStatus(_ status: DictationOutputCommitStatus) {
    commitStatus = status
}
```

The reservation shape is already required in Task 3. Keep this shape while adding deadlines and race coverage; an output suspension cannot strand an old stream or overwrite a newer active session:

```swift
private struct FinishReservation {
    let token: SessionToken
    let terminal: DictationTerminal
    let sequence: UInt64
    let continuation: AsyncStream<DictationSessionEventEnvelope>.Continuation
}

private func reserveFinish(
    _ terminal: DictationTerminal,
    token: SessionToken,
    generation: UInt64
) -> FinishReservation? {
    guard var current = matching(token: token, generation: generation),
          !current.finishStarted else { return nil }
    current.finishStarted = true
    cancelDeadlines(in: &current)
    current.audioCapture?.stop()
    if let gate = current.bufferGate {
        gate.close(mode: terminal.bufferCloseMode)
    } else {
        current.speech?.cancel()
    }
    audioSession.deactivate()
    active = nil
    return FinishReservation(
        token: token,
        terminal: terminal,
        sequence: current.nextSequence,
        continuation: current.continuation
    )
}

private func finish(
    _ terminal: DictationTerminal,
    token: SessionToken,
    generation: UInt64
) async {
    guard let reservation = reserveFinish(
        terminal,
        token: token,
        generation: generation
    ) else { return }
    await completeFinish(reservation)
}

private func completeFinish(_ reservation: FinishReservation) async {
    let status = await output.commit(reservation.terminal, token: reservation.token)
    let event: DictationSessionEvent
    switch status {
    case .written, .alreadyTerminal:
        event = reservation.terminal.event
    case .cancelled:
        event = .cancelled
    case .ioFailure:
        event = .failed(.outputPersistence)
    }
    reservation.continuation.yield(
        DictationSessionEventEnvelope(
            token: reservation.token,
            sequence: reservation.sequence,
            event: event
        )
    )
    reservation.continuation.finish()
}
```

At the start of `start`, reserve the previous session synchronously and launch only its frozen completion before installing the new active record:

```swift
if let previous = active,
   let reservation = reserveFinish(
       .cancelled,
       token: previous.request.token,
       generation: previous.generation
   ) {
    Task { await self.completeFinish(reservation) }
}
```

Keep `start` free of any awaited old-session finish, as implemented in Task 3. This preserves actor-admission order while each older stream receives its own cancelled terminal. Preserve the post-publication token/generation/authorizing ownership guard before requesting permission.

- [ ] **Step 6: Add and pass the 50-session reuse gate**

Add this deterministic test:

```swift
func testFiftySequentialSessionsLeaveNoCrossSessionEffect() async throws {
    let harness = EngineHarness()
    var tokens: Set<SessionToken> = []

    for index in 0..<50 {
        let request = harness.makeRequest()
        XCTAssertTrue(tokens.insert(request.token).inserted)
        let events = Task { await collectEvents(await harness.engine.start(request)) }
        await harness.waitForSpeechSessionCount(index + 1)
        harness.speech.send(
            .success(.init(transcript: "结果\(index)", isFinal: true)),
            index: index
        )
        let received = await events.value
        XCTAssertEqual(received.filter(\.event.isTerminal).count, 1)
        XCTAssertTrue(received.allSatisfy { $0.token == request.token })
    }

    let terminals = await harness.output.terminals
    XCTAssertEqual(terminals.count, 50)
    XCTAssertEqual(Set(terminals.map(\.1)), tokens)
}
```

Run:

```bash
xcodebuild test -project VoType.xcodeproj -scheme VoTypeTests -destination "platform=iOS Simulator,id=$SIM_ID" CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION="$PLAN_BUILD_NUMBER" -only-testing:VoTypeTests/DictationSessionEngineTests -derivedDataPath ./slice_a_test_build
```

Expected: PASS for all lifecycle, 100-schedule race, and 50-session tests.

- [ ] **Step 7: Commit race hardening**

```bash
git add VoiceInputApp/DictationSessionEngine.swift VoTypeTests/DictationSessionTestDoubles.swift VoTypeTests/DictationSessionEngineTests.swift
git commit -m "test: harden dictation lifecycle races"
```

---

### Task 5: Production Apple, Text Processing, and Darwin Adapters

**Files:**
- Create: `VoiceInputApp/AppleDictationAdapters.swift`
- Create: `VoiceInputApp/DictationSessionEnvironment.swift`
- Create: `VoTypeTests/AppleDictationAdaptersTests.swift`
- Modify: `Shared/DarwinBridge.swift:225-297, 433-666`
- Modify: `Shared/TextProcessor.swift:175-227, 292-310`
- Modify: `VoTypeTests/TextProcessorTests.swift:57-177`

**Interfaces:**
- Consumes: Task 2 ports, `TextProcessor.process`, `DictationLiveStatePublisher`, AVFoundation, Speech, and NotificationCenter.
- Produces: production dependency implementations and `DictationSessionEnvironment.shared.engine`, the only engine used by Tasks 6 and 7.

- [ ] **Step 1: Write failing permission-policy tests**

In `VoTypeTests/AppleDictationAdaptersTests.swift`, test a pure decision reducer before touching system APIs:

```swift
func testReadOnlyPolicyNeverRequestsUndeterminedPermission() {
    XCTAssertEqual(
        DictationPermissionDecision.next(
            speech: .notDetermined,
            microphone: .authorized,
            policy: .readOnly
        ),
        .fail(.permissionRequiresForeground(.speech))
    )
    XCTAssertEqual(
        DictationPermissionDecision.next(
            speech: .authorized,
            microphone: .notDetermined,
            policy: .readOnly
        ),
        .fail(.permissionRequiresForeground(.microphone))
    )
}

func testForegroundPolicyRequestsOnlyTheMissingPermission() {
    XCTAssertEqual(
        DictationPermissionDecision.next(
            speech: .notDetermined,
            microphone: .authorized,
            policy: .requestIfNeeded
        ),
        .requestSpeech
    )
    XCTAssertEqual(
        DictationPermissionDecision.next(
            speech: .authorized,
            microphone: .notDetermined,
            policy: .requestIfNeeded
        ),
        .requestMicrophone
    )
}
```

Use local enums `DictationAuthorizationState` and `DictationPermissionDecision` with cases `.authorized`, `.denied`, `.notDetermined` and `.proceed`, `.requestSpeech`, `.requestMicrophone`, `.fail(DictationFailure)`.

- [ ] **Step 2: Write failing text-plan mapping tests**

Add:

```swift
func testTextAdapterMapsDictationAndSelectedEditsSafely() async throws {
    let plain = makeSnapshot(selectedText: nil, voiceEditEnabled: true)
    XCTAssertEqual(
        TextProcessorDictationAdapter.plan(
            from: .insert("你好。"),
            snapshot: plain
        ),
        .success(
            EditPlan(
                intent: .dictate,
                operation: .insertAtCursor,
                text: "你好。",
                expectedContextFingerprint: plain.expectedContextFingerprint,
                requiresConfirmation: false
            )
        )
    )

    let selected = makeSnapshot(selectedText: "旧文本", voiceEditEnabled: true)
    XCTAssertEqual(
        TextProcessorDictationAdapter.plan(
            from: .deleteSelection,
            snapshot: selected
        ),
        .success(
            EditPlan(
                intent: .delete,
                operation: .deleteSelection,
                text: "",
                expectedContextFingerprint: selected.expectedContextFingerprint,
                requiresConfirmation: true
            )
        )
    )

    XCTAssertEqual(
        TextProcessorDictationAdapter.plan(
            from: .insert("新文本"),
            snapshot: selected
        ),
        .success(
            EditPlan(
                intent: .rewrite,
                operation: .replaceSelection,
                text: "新文本",
                expectedContextFingerprint: selected.expectedContextFingerprint,
                requiresConfirmation: true
            )
        )
    )

    var translated = makeSnapshot(selectedText: nil, voiceEditEnabled: true)
    translated = TextProcessingSnapshot(
        selectedText: translated.selectedText,
        keyboardType: translated.keyboardType,
        language: translated.language,
        translateEnabled: true,
        translateTarget: "en-US",
        voiceEditEnabled: translated.voiceEditEnabled,
        livePreviewEnabled: translated.livePreviewEnabled,
        expectedContextFingerprint: translated.expectedContextFingerprint
    )
    XCTAssertEqual(
        TextProcessorDictationAdapter.plan(from: .insert("Hello."), snapshot: translated),
        .success(
            EditPlan(
                intent: .translate(targetLanguage: "en-US"),
                operation: .insertAtCursor,
                text: "Hello.",
                expectedContextFingerprint: translated.expectedContextFingerprint,
                requiresConfirmation: false
            )
        )
    )

    XCTAssertEqual(
        TextProcessorDictationAdapter.plan(from: .failure(.emptyOutput), snapshot: plain),
        .failure(.processing)
    )
}

private func makeSnapshot(
    selectedText: String?,
    voiceEditEnabled: Bool
) -> TextProcessingSnapshot {
    TextProcessingSnapshot(
        selectedText: selectedText,
        keyboardType: 0,
        language: "zh-CN",
        translateEnabled: false,
        translateTarget: "en-US",
        voiceEditEnabled: voiceEditEnabled,
        livePreviewEnabled: true,
        expectedContextFingerprint: "context-digest"
    )
}
```

Add this regression to `VoTypeTests/TextProcessorTests.swift` so the value captured in the session snapshot wins over a setting changed after the session began:

```swift
func testVoiceEditUsesExplicitSessionSnapshotInsteadOfLiveDefaults() async {
    defaults.set(true, forKey: "voiceEdit")
    let disabledForSession = await processor.process(
        "删除",
        selectedText: "必须保留",
        language: "zh-CN",
        translateEnabled: false,
        translateTarget: "en-US",
        voiceEditEnabled: false
    )
    XCTAssertEqual(disabledForSession, .insert("删除。"))

    defaults.set(false, forKey: "voiceEdit")
    let enabledForSession = await processor.process(
        "删除",
        selectedText: "需要删除",
        language: "zh-CN",
        translateEnabled: false,
        translateTarget: "en-US",
        voiceEditEnabled: true
    )
    XCTAssertEqual(enabledForSession, .deleteSelection)
}
```

Add the required `voiceEditEnabled:` argument to every existing nondeprecated `process` call in `TextProcessorTests`: use `true` for the existing voice-edit cases and `false` for ordinary dictation/translation cases. Do not change any processing algorithm; this task only removes the live-default read from the per-session path.

- [ ] **Step 3: Run adapter tests and observe missing production types**

Run:

```bash
xcodebuild test -project VoType.xcodeproj -scheme VoTypeTests -destination "platform=iOS Simulator,id=$SIM_ID" CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION="$PLAN_BUILD_NUMBER" -only-testing:VoTypeTests/AppleDictationAdaptersTests -only-testing:VoTypeTests/TextProcessorTests -derivedDataPath ./slice_a_test_build
```

Expected: FAIL because the permission reducer/text adapter are absent and the typed processor has not yet accepted the explicit voice-edit snapshot.

- [ ] **Step 4: Implement permission, audio-session, and event-source adapters**

In `AppleDictationAdapters.swift`:

- `AppleDictationPermissionResolver` loops over `DictationPermissionDecision.next`, calls `SFSpeechRecognizer.requestAuthorization` or `AVAudioSession.requestRecordPermission` only for `.requestIfNeeded`, and returns immediately for `.readOnly` failures.
- `AppleDictationAudioSessionController.activate(whisper:)` preserves the current category/options: `.playAndRecord`, `.voiceChat` only for whisper, `.default` otherwise, and `[.allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers]`; `deactivate()` uses `.notifyOthersOnDeactivation`.
- `AppleDictationAudioSystemEventSource` converts interruption-began, old-device-unavailable route change, and media-services reset notifications to `DictationAudioSystemEvent`. It emits no resume event.

Implement the tested reducer exactly:

```swift
enum DictationAuthorizationState: Equatable {
    case authorized
    case denied
    case notDetermined
}

enum DictationPermissionDecision: Equatable {
    case proceed
    case requestSpeech
    case requestMicrophone
    case fail(DictationFailure)

    static func next(
        speech: DictationAuthorizationState,
        microphone: DictationAuthorizationState,
        policy: DictationAuthorizationPolicy
    ) -> DictationPermissionDecision {
        if speech == .denied { return .fail(.permissionDenied(.speech)) }
        if microphone == .denied { return .fail(.permissionDenied(.microphone)) }
        if speech == .notDetermined {
            return policy == .requestIfNeeded
                ? .requestSpeech
                : .fail(.permissionRequiresForeground(.speech))
        }
        if microphone == .notDetermined {
            return policy == .requestIfNeeded
                ? .requestMicrophone
                : .fail(.permissionRequiresForeground(.microphone))
        }
        return .proceed
    }
}
```

`AppleDictationPermissionResolver.authorize` reevaluates this reducer after each requested authorization. Its `.readOnly` branch has no calls to either request API.

Use an `AsyncStream` whose `onTermination` removes every NotificationCenter observer. The environment starts exactly one task that forwards this stream to the engine.

- [ ] **Step 5: Implement Speech and capture adapters with no per-buffer tasks**

`AppleSpeechSessionFactory.makeSession` creates `SFSpeechRecognizer`, verifies `isAvailable`, creates `SFSpeechAudioBufferRecognitionRequest`, enables partials, sets `requiresOnDeviceRecognition` only when supported, and maps callbacks to `DictationRecognitionUpdate` or `.recognition`.

`AppleAudioCaptureFactory.makeSession` owns one `AVAudioEngine`. Its input-tap callback must be exactly a direct call to the supplied handler:

```swift
inputNode.installTap(
    onBus: 0,
    bufferSize: 1_024,
    format: recordingFormat
) { buffer, _ in
    bufferHandler(buffer)
}
```

`stop()` stops the engine and removes the tap once. A repository search for `installTap` after Tasks 6 and 7 must find only this production adapter.

- [ ] **Step 6: Make voice-edit processing immutable, then implement text and Darwin output adapters**

Add `voiceEditEnabled: Bool` as a required final argument of the typed `TextProcessor.process` method and replace its `if voiceEditEnabled` property read with that argument. In the deprecated string-returning overload, capture the live setting once and pass it explicitly so only legacy callers retain legacy behavior. `TextProcessorDictationAdapter.process` must pass every field from its immutable `TextProcessingSnapshot`, including `snapshot.voiceEditEnabled`; it must not reread `TextProcessor.shared` or `UserDefaults` while processing. Selected replacement/deletion always requires confirmation. `livePreviewEnabled` controls only whether `DarwinDictationSessionOutput` persists a nonempty partial; Speech partials remain enabled internally.

The adapter call is exactly:

```swift
let result = await processor.process(
    rawText,
    selectedText: snapshot.selectedText,
    keyboardType: snapshot.keyboardType,
    language: snapshot.language,
    translateEnabled: snapshot.translateEnabled,
    translateTarget: snapshot.translateTarget,
    voiceEditEnabled: snapshot.voiceEditEnabled
)
return Self.plan(from: result, snapshot: snapshot)
```

Implement the pure mapping as:

```swift
static func plan(
    from result: TextProcessingResult,
    snapshot: TextProcessingSnapshot
) -> Result<EditPlan, DictationFailure> {
    switch result {
    case .failure:
        return .failure(.processing)
    case .deleteSelection:
        return .success(
            EditPlan(
                intent: .delete,
                operation: .deleteSelection,
                text: "",
                expectedContextFingerprint: snapshot.expectedContextFingerprint,
                requiresConfirmation: true
            )
        )
    case .insert(let text):
        let hasSelectedEdit = snapshot.voiceEditEnabled
            && !(snapshot.selectedText?.isEmpty ?? true)
        let intent: EditIntent = snapshot.translateEnabled
            ? .translate(targetLanguage: snapshot.translateTarget)
            : (hasSelectedEdit ? .rewrite : .dictate)
        return .success(
            EditPlan(
                intent: intent,
                operation: hasSelectedEdit ? .replaceSelection : .insertAtCursor,
                text: text,
                expectedContextFingerprint: snapshot.expectedContextFingerprint,
                requiresConfirmation: hasSelectedEdit
            )
        )
    }
}
```

`DarwinDictationSessionOutput.publishLive` maps:

```swift
.authorizing, .preparing       -> .starting
.listening(let partial)        -> .listening
.processing                    -> .processing
.completed, .failed, .cancelled -> no live write
```

It reuses one `DictationLiveStatePublisher` per token and never creates a second throttler. `commit` calls `DarwinBridge.commit`, clears the matching publisher, and posts the existing session-scoped started/failed/stopped notifications only for their truthful state transitions.

- [ ] **Step 7: Compose exactly one production engine**

Create `VoiceInputApp/DictationSessionEnvironment.swift`:

```swift
final class DictationSessionEnvironment: @unchecked Sendable {
    static let shared = DictationSessionEnvironment()

    let engine: DictationSessionEngine
    private let eventForwardingTask: Task<Void, Never>

    private init() {
        let eventSource = AppleDictationAudioSystemEventSource()
        let engine = DictationSessionEngine(
            permissions: AppleDictationPermissionResolver(),
            audioSession: AppleDictationAudioSessionController(),
            speechFactory: AppleSpeechSessionFactory(),
            audioFactory: AppleAudioCaptureFactory(),
            scheduler: DispatchDeadlineScheduler(),
            processor: TextProcessorDictationAdapter(processor: .shared),
            output: DarwinDictationSessionOutput(),
            deadlines: .production
        )
        self.engine = engine
        self.eventForwardingTask = Task {
            for await event in eventSource.events {
                await engine.handleAudioSystemEvent(event)
            }
        }
    }
}
```

Keep `eventSource` strongly retained by the forwarding task capture. No other production engine may be created outside tests.

- [ ] **Step 8: Run adapter, engine, IPC, and buffer tests**

Run:

```bash
xcodebuild test \
  -project VoType.xcodeproj \
  -scheme VoTypeTests \
  -destination "platform=iOS Simulator,id=$SIM_ID" \
  CODE_SIGNING_ALLOWED=NO \
  CURRENT_PROJECT_VERSION="$PLAN_BUILD_NUMBER" \
  -only-testing:VoTypeTests/AppleDictationAdaptersTests \
  -only-testing:VoTypeTests/DictationSessionEngineTests \
  -only-testing:VoTypeTests/DictationAudioBufferGateTests \
  -only-testing:VoTypeTests/DictationConstantsTests \
  -only-testing:VoTypeTests/TextProcessorTests \
  -derivedDataPath ./slice_a_test_build
```

Expected: PASS. This proves policy and state behavior only; it does not prove real microphone, route, Speech, or PiP behavior.

- [ ] **Step 9: Commit production adapters**

```bash
git add VoiceInputApp/AppleDictationAdapters.swift VoiceInputApp/DictationSessionEnvironment.swift Shared/DarwinBridge.swift Shared/TextProcessor.swift VoTypeTests/AppleDictationAdaptersTests.swift VoTypeTests/TextProcessorTests.swift
git commit -m "feat: connect dictation engine adapters"
```

---

### Task 6: Migrate the PiP/In-Place Adapter

**Files:**
- Modify: `VoiceInputApp/BackgroundDictationManager.swift:1-741`
- Modify: `VoiceInputApp/PiPStandbyManager.swift:18-177`
- Create: `VoTypeTests/BackgroundDictationManagerTests.swift`
- Modify: `VoTypeTests/DictationSessionTestDoubles.swift`
- Modify: `VoTypeTests/PiPStandbyManagerTests.swift`

**Interfaces:**
- Consumes: `DictationSessionEnvironment.shared.engine`, `DictationSessionRunning`, existing Darwin request/stop/cancel notifications, `DictationSettings`, and PiP state methods.
- Produces: a thin `@MainActor` background adapter that always starts `.inPlace` with `.readOnly` authorization and owns no Speech/audio lifecycle object.

- [ ] **Step 1: Write failing in-place adapter tests**

Create an actor `RecordingSessionRunner` implementing `DictationSessionRunning` and tests that call an internal `handlePendingRequest()` seam:

```swift
@MainActor
func testHotRequestUsesReadOnlyPolicyAndMirrorsEngineEvents() async throws {
    let runner = RecordingSessionRunner(events: [
        .preparing,
        .listening(partial: "你好"),
        .processing,
        .completed(
            EditPlan(
                intent: .dictate,
                operation: .insertAtCursor,
                text: "你好。",
                expectedContextFingerprint: nil,
                requiresConfirmation: false
            )
        )
    ])
    let pip = RecordingPiPStandbyPresenter(isActive: true)
    let manager = BackgroundDictationManager(engine: runner, pip: pip)
    let settings = makeStoredSettings(session: UUID().uuidString)

    await manager.handlePendingRequest()

    let requests = await runner.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.token.rawValue, settings.session)
    XCTAssertEqual(request.entryPoint, .inPlace)
    XCTAssertEqual(request.authorizationPolicy, .readOnly)
    XCTAssertEqual(pip.states, [
        .recording(""),
        .recording("你好"),
        .processing("你好") ,
        .standby
    ])
}

@MainActor
func testPermissionRequiredTerminatesWithoutRequeueAndDisablesReadiness() async throws {
    let runner = RecordingSessionRunner(events: [
        .failed(.permissionRequiresForeground(.microphone))
    ])
    let pip = RecordingPiPStandbyPresenter(isActive: true)
    let manager = BackgroundDictationManager(engine: runner, pip: pip)
    let settings = makeStoredSettings(session: UUID().uuidString)

    await manager.handlePendingRequest()

    XCTAssertNil(DarwinBridge.peekDictationSettings(expectedSession: settings.session))
    XCTAssertNil(DarwinBridge.peekPendingDictationSettings())
    XCTAssertEqual(pip.stopStandbyCount, 1)
}

@MainActor
func testInactivePiPIgnoresPendingRequest() async throws {
    let runner = RecordingSessionRunner(events: [.preparing])
    let pip = RecordingPiPStandbyPresenter(isActive: false)
    let manager = BackgroundDictationManager(engine: runner, pip: pip)
    _ = makeStoredSettings(session: UUID().uuidString)
    await manager.handlePendingRequest()
    let requests = await runner.requests
    XCTAssertTrue(requests.isEmpty)
}

@MainActor
func testStopAndCancelForwardOnlyCurrentToken() async throws {
    let runner = RecordingSessionRunner(events: [.listening(partial: "")])
    let pip = RecordingPiPStandbyPresenter(isActive: true)
    let manager = BackgroundDictationManager(engine: runner, pip: pip)
    let settings = makeStoredSettings(session: UUID().uuidString)
    await manager.handlePendingRequest()

    await manager.handleStopNotification(session: settings.session)
    await manager.handleCancelNotification(session: settings.session)

    let token = try XCTUnwrap(SessionToken(rawValue: settings.session))
    let stoppedTokens = await runner.stoppedTokens
    let cancelledTokens = await runner.cancelledTokens
    XCTAssertEqual(stoppedTokens, [token])
    XCTAssertEqual(cancelledTokens, [token])
}
```

Add these reusable fakes to `VoTypeTests/DictationSessionTestDoubles.swift`:

```swift
actor RecordingSessionRunner: DictationSessionRunning {
    let events: [DictationSessionEvent]
    private(set) var requests: [DictationSessionRequest] = []
    private(set) var stoppedTokens: [SessionToken] = []
    private(set) var cancelledTokens: [SessionToken] = []
    private(set) var audioEvents: [DictationAudioSystemEvent] = []

    init(events: [DictationSessionEvent]) { self.events = events }

    func start(
        _ request: DictationSessionRequest
    ) async -> AsyncStream<DictationSessionEventEnvelope> {
        requests.append(request)
        return AsyncStream { continuation in
            for (offset, event) in events.enumerated() {
                continuation.yield(
                    DictationSessionEventEnvelope(
                        token: request.token,
                        sequence: UInt64(offset + 1),
                        event: event
                    )
                )
            }
            continuation.finish()
        }
    }

    func stop(token: SessionToken) async { stoppedTokens.append(token) }
    func cancel(token: SessionToken) async { cancelledTokens.append(token) }
    func handleAudioSystemEvent(_ event: DictationAudioSystemEvent) async {
        audioEvents.append(event)
    }
}

@MainActor
final class RecordingPiPStandbyPresenter: PiPStandbyPresenting {
    enum RecordedState: Equatable {
        case recording(String)
        case processing(String)
        case standby
    }
    let isActive: Bool
    private(set) var states: [RecordedState] = []
    private(set) var stopStandbyCount = 0

    init(isActive: Bool) { self.isActive = isActive }
    func setRecording(text: String) { states.append(.recording(text)) }
    func setProcessing(text: String) { states.append(.processing(text)) }
    func returnToStandby() { states.append(.standby) }
    func stopStandby() { stopStandbyCount += 1 }
}
```

In `BackgroundDictationManagerTests.setUp`, create a unique temporary directory and call `DarwinBridge.setContainerDirectoryForTesting(directory)`; in `tearDown`, call `DarwinBridge.resetContainerDirectoryAfterTesting()` and remove that exact directory. Define the helper used above as:

```swift
@discardableResult
private func makeStoredSettings(session: String) -> DictationSettings {
    let settings = DictationSettings(
        language: "zh-CN",
        whisper: false,
        translateEnabled: false,
        translateTarget: "en-US",
        selectedText: nil,
        keyboardType: 0,
        session: session
    )
    XCTAssertTrue(DarwinBridge.writeDictationSettings(settings))
    return settings
}
```

- [ ] **Step 2: Run the new suite and confirm the adapter seams are absent**

Run:

```bash
xcodebuild test -project VoType.xcodeproj -scheme VoTypeTests -destination "platform=iOS Simulator,id=$SIM_ID" CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION="$PLAN_BUILD_NUMBER" -only-testing:VoTypeTests/BackgroundDictationManagerTests -derivedDataPath ./slice_a_test_build
```

Expected: FAIL because `BackgroundDictationManager` cannot inject the runner/PiP presenter and still owns the duplicate recorder.

- [ ] **Step 3: Add a minimal PiP presentation protocol**

Define next to `PiPStandbyManager`:

```swift
@MainActor
protocol PiPStandbyPresenting: AnyObject {
    var isActive: Bool { get }
    func setRecording(text: String)
    func setProcessing(text: String)
    func returnToStandby()
    func stopStandby()
}

extension PiPStandbyManager: PiPStandbyPresenting {}
```

Do not change PiP rendering, startup watchdog, or background-mode configuration in this task.

- [ ] **Step 4: Replace duplicate recording with engine adaptation**

Refactor `BackgroundDictationManager` to retain only:

- the injected `any DictationSessionRunning`;
- the injected `any PiPStandbyPresenting`;
- Darwin observers;
- current token and one event-consumer task;
- mapping engine events to visible PiP state and explicit retry/manual recovery.

Make internal `handlePendingRequest`, `handleStopNotification(session:)`, and `handleCancelNotification(session:)` async so tests can await command delivery. Register separate session-scoped observers: `requestStopDictation` always calls `engine.stop(token:)`; `requestCancelDictation` always calls `engine.cancel(token:)`, including while processing. Neither handler infers one command from the other or branches on phase. Darwin observer closures start one `Task { @MainActor in ... }` for each control notification.

The production singleton is:

```swift
static let shared = BackgroundDictationManager(
    engine: DictationSessionEnvironment.shared.engine,
    pip: PiPStandbyManager.shared
)
```

Build a request only after consuming a valid UUID-scoped `DictationSettings`:

```swift
let request = DictationSessionRequest(
    token: token,
    entryPoint: .inPlace,
    authorizationPolicy: .readOnly,
    whisper: settings.whisper,
    processing: TextProcessingSnapshot(
        selectedText: settings.selectedText,
        keyboardType: settings.keyboardType,
        language: settings.language,
        translateEnabled: settings.translateEnabled,
        translateTarget: settings.translateTarget,
        voiceEditEnabled: TextProcessor.shared.voiceEditEnabled,
        livePreviewEnabled: TextProcessor.shared.livePreviewEnabled,
        expectedContextFingerprint: settings.expectedContextFingerprint
    )
)
```

At `.preparing`, post the existing session-scoped `dictationStarted` acknowledgement so the keyboard receives it within its 1.2-second hot deadline. At permission-required, recognition-unavailable-before-listening, or start-timeout failures, stop PiP standby to invalidate readiness and expose the session-scoped failure with explicit Retry guidance. Never requeue the same settings after an engine terminal: the terminal receipt must continue to reject that UUID. All engine failures are terminal and are not silently restarted. The subsequent explicit keyboard Retry creates a fresh UUID through the ordinary launch path, which is manual-only after readiness is cleared. Do not apply the nonterminal hot-timeout handoff to an already-terminal source.

Add an integration regression using the real engine and Darwin output with injected permission/audio dependencies: a pre-listening permission failure consumes the original pending request, leaves no pending file for its terminal UUID, and its terminal receipt rejects later commits. Keep the manager unit test above separate from that persistence test; a fake runner must not be treated as evidence that production terminal persistence occurred. Task 8 adds the fresh explicit Retry and held/manual disposition assertions.

Delete every `AVAudioEngine`, `SFSpeechRecognizer`, recognition request/task, generation, silence timer, permission, audio-interruption, and terminal-write member from this manager. After the edit, `rg -n "AVAudioEngine|SFSpeech|installTap|writeTranscription|writeError" VoiceInputApp/BackgroundDictationManager.swift` must return no matches.

- [ ] **Step 5: Run background/PiP and engine suites**

Run:

```bash
xcodebuild test \
  -project VoType.xcodeproj \
  -scheme VoTypeTests \
  -destination "platform=iOS Simulator,id=$SIM_ID" \
  CODE_SIGNING_ALLOWED=NO \
  CURRENT_PROJECT_VERSION="$PLAN_BUILD_NUMBER" \
  -only-testing:VoTypeTests/BackgroundDictationManagerTests \
  -only-testing:VoTypeTests/PiPStandbyManagerTests \
  -only-testing:VoTypeTests/PiPLaunchPolicyTests \
  -only-testing:VoTypeTests/DictationSessionEngineTests \
  -derivedDataPath ./slice_a_test_build
```

Expected: PASS; PiP startup watchdog behavior remains unchanged.

- [ ] **Step 6: Commit the in-place migration**

```bash
git add VoiceInputApp/BackgroundDictationManager.swift VoiceInputApp/PiPStandbyManager.swift VoTypeTests/BackgroundDictationManagerTests.swift VoTypeTests/DictationSessionTestDoubles.swift VoTypeTests/PiPStandbyManagerTests.swift
git commit -m "refactor: route pip dictation through engine"
```

---

### Task 7: Migrate the Foreground Presentation Adapter

**Files:**
- Modify: `VoiceInputApp/DictationView.swift:1-742, 768-887`
- Modify: `VoiceInputApp/VoiceInputApp.swift:4-88`
- Modify: `VoTypeTests/DictationViewModelTests.swift`
- Create: `VoTypeTests/DictationCoordinatorTests.swift`
- Modify: `VoTypeTests/DictationSessionTestDoubles.swift`

**Interfaces:**
- Consumes: the shared engine environment, Task 1's non-consuming exact settings lookup, Task 2's injectable deadline scheduler, and existing pending-request discovery.
- Produces: a `@MainActor` `DictationViewModel` that presents ordinary no-deep-link requests, claims the exact request at the first `.authorizing` acknowledgement within 3 seconds, requests permission only in foreground, mirrors ordered engine events, and owns no Apple recording/recognition resource.

- [ ] **Step 1: Replace recorder-centric tests with claim, timeout, and adapter contract tests**

Keep the current URL/session validation coverage, but change its consumption assertion: `loadSettings` may only peek the exact request; the first matching `.authorizing` event claims it. Add an injected runner and these behaviors:

```swift
@MainActor
func testStartUsesForegroundPermissionPolicyAndMirrorsEvents() async throws {
    let token = SessionToken()
    let runner = RecordingSessionRunner(events: [
        .authorizing,
        .preparing,
        .listening(partial: "你好"),
        .processing,
        .completed(
            EditPlan(
                intent: .dictate,
                operation: .insertAtCursor,
                text: "你好。",
                expectedContextFingerprint: nil,
                requiresConfirmation: false
            )
        )
    ])
    let model = DictationViewModel(engine: runner)
    let settings = makeSettings(token: token)
    XCTAssertTrue(DarwinBridge.writeDictationSettings(settings))
    model.loadSettings(from: nil, expectedSession: token.rawValue)
    XCTAssertEqual(
        DarwinBridge.peekDictationSettings(expectedSession: token.rawValue),
        settings
    )

    await model.startRecording()

    let requests = await runner.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.entryPoint, .foreground)
    XCTAssertEqual(request.authorizationPolicy, .requestIfNeeded)
    XCTAssertEqual(model.liveText, "你好")
    XCTAssertTrue(model.hasResult)
    XCTAssertEqual(model.statusMessage, "识别完成 ✓")
    XCTAssertNil(DarwinBridge.peekDictationSettings(expectedSession: token.rawValue))
}

@MainActor
func testStopAndCancelForwardOnlyTheLoadedToken() async throws {
    let token = SessionToken()
    let runner = RecordingSessionRunner(events: [
        .authorizing,
        .listening(partial: "")
    ])
    let model = DictationViewModel(engine: runner)
    XCTAssertTrue(DarwinBridge.writeDictationSettings(makeSettings(token: token)))
    model.loadSettings(from: nil, expectedSession: token.rawValue)
    await model.startRecording()
    await model.stopRecording()
    await model.cancelRecording()
    let stoppedTokens = await runner.stoppedTokens
    let cancelledTokens = await runner.cancelledTokens
    XCTAssertEqual(stoppedTokens, [token])
    XCTAssertEqual(cancelledTokens, [token])
}

@MainActor
func testRepeatedStartWhileStreamIsActiveIssuesOnlyOneEngineStart() async {
    let token = SessionToken()
    let runner = RecordingSessionRunner(
        events: [.authorizing, .listening(partial: "")],
        finishesStream: false
    )
    let model = DictationViewModel(engine: runner)
    XCTAssertTrue(DarwinBridge.writeDictationSettings(makeSettings(token: token)))
    model.loadSettings(from: nil, expectedSession: token.rawValue)

    let firstStart = Task { await model.startRecording() }
    await runner.waitForRequestCount(1)
    await model.startRecording()

    let requests = await runner.requests
    XCTAssertEqual(requests.count, 1)
    await runner.finishOpenStreams()
    await firstStart.value
}

private func makeSettings(token: SessionToken) -> DictationSettings {
    DictationSettings(
        language: "zh-CN",
        whisper: false,
        translateEnabled: false,
        translateTarget: "en-US",
        selectedText: nil,
        keyboardType: 0,
        session: token.rawValue
    )
}
```

Extend `RecordingSessionRunner` with `finishesStream: Bool = true`, retained continuations when false, `waitForRequestCount(_:)`, and `finishOpenStreams()`. Protect all of that state inside the actor; the default keeps every Task 6 test unchanged.

Add the controlled 3-second boundary and competing-consumer cases to the same file:

```swift
@MainActor
func testForegroundClaimTimeoutLeavesSettingsPendingAndNeverStartsEngine() async {
    let token = SessionToken()
    let runner = RecordingSessionRunner(events: [.authorizing])
    let scheduler = ManualDeadlineScheduler()
    let model = DictationViewModel(
        engine: runner,
        scheduler: scheduler,
        deadlines: .production
    )
    let settings = makeSettings(token: token)
    XCTAssertTrue(DarwinBridge.writeDictationSettings(settings))

    model.loadSettings(from: nil, expectedSession: token.rawValue)
    scheduler.fire(interval: DictationSessionDeadlines.production.foregroundClaim)
    await Task.yield()
    await model.startRecording()

    let requests = await runner.requests
    XCTAssertTrue(requests.isEmpty)
    XCTAssertEqual(model.permissionError, "未能启动该语音请求，请返回键盘重试")
    XCTAssertTrue(model.canExit)
    XCTAssertEqual(
        DarwinBridge.peekDictationSettings(expectedSession: token.rawValue),
        settings
    )
}

@MainActor
func testAuthorizingFailsClosedWhenAnotherConsumerWonTheClaim() async {
    let token = SessionToken()
    let runner = RecordingSessionRunner(events: [.authorizing, .preparing])
    let model = DictationViewModel(engine: runner)
    XCTAssertTrue(DarwinBridge.writeDictationSettings(makeSettings(token: token)))
    model.loadSettings(from: nil, expectedSession: token.rawValue)
    XCTAssertNotNil(
        DarwinBridge.readAndConsumeDictationSettings(
            expectedSession: token.rawValue
        )
    )

    await model.startRecording()

    let cancelledTokens = await runner.cancelledTokens
    XCTAssertEqual(cancelledTokens, [token])
    XCTAssertEqual(model.permissionError, "该语音请求已由另一入口处理，请返回键盘重试")
    XCTAssertFalse(model.hasResult)
}
```

Create `VoTypeTests/DictationCoordinatorTests.swift` with the same unique temporary App Group directory setup/teardown used by `DictationViewModelTests`, then prove the normal manual-open path needs no URL:

```swift
@MainActor
func testActiveAppEnqueuesPendingRequestWithoutDeepLink() throws {
    let token = SessionToken()
    XCTAssertTrue(
        DarwinBridge.writeDictationSettings(
            DictationSettings(
                language: "zh-CN",
                whisper: false,
                translateEnabled: false,
                translateTarget: "en-US",
                selectedText: nil,
                keyboardType: 0,
                session: token.rawValue
            )
        )
    )
    let coordinator = DictationCoordinator()

    coordinator.enqueuePendingIfAvailable()

    XCTAssertEqual(coordinator.presentation?.id, token.rawValue)
    XCTAssertNil(coordinator.presentation?.url)
    XCTAssertNotNil(
        DarwinBridge.peekDictationSettings(expectedSession: token.rawValue)
    )
}
```

- [ ] **Step 2: Run `DictationViewModelTests` and observe the missing injection path**

Run:

```bash
xcodebuild test -project VoType.xcodeproj -scheme VoTypeTests -destination "platform=iOS Simulator,id=$SIM_ID" CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION="$PLAN_BUILD_NUMBER" -only-testing:VoTypeTests/DictationViewModelTests -only-testing:VoTypeTests/DictationCoordinatorTests -derivedDataPath ./slice_a_test_build
```

Expected: FAIL because the view model still owns AVFoundation/Speech, consumes settings during `loadSettings`, lacks injected engine/deadline seams, and the coordinator has no testable pending-enqueue method.

- [ ] **Step 3: Convert `DictationViewModel` into presentation state only**

Keep its public SwiftUI state and URL/session parsing. Replace all recorder fields and system observers with these dependencies and claim state:

```swift
private let engine: any DictationSessionRunning
private let scheduler: any DictationDeadlineScheduling
private let deadlines: DictationSessionDeadlines
private var sessionToken: SessionToken?
private var loadedSettings: DictationSettings?
private var request: DictationSessionRequest?
private var foregroundClaimTask: (any DictationScheduledTask)?
private var settingsClaimed = false
private var foregroundClaimExpired = false
private var engineStartIssued = false

init(
    engine: any DictationSessionRunning = DictationSessionEnvironment.shared.engine,
    scheduler: any DictationDeadlineScheduling = DispatchDeadlineScheduler(),
    deadlines: DictationSessionDeadlines = .production
) {
    self.engine = engine
    self.scheduler = scheduler
    self.deadlines = deadlines
}
```

`loadSettings` must use `DarwinBridge.peekDictationSettings(expectedSession:)` for an explicit/deep-link session, or `peekPendingDictationSettings()` only when both URL and explicit session are absent. It must never consume. Reject invalid/cancelled settings, otherwise build and store the complete `DictationSessionRequest` immediately, capturing `voiceEditEnabled` and `livePreviewEnabled` once. Arm the claim deadline at that point:

```swift
foregroundClaimTask = scheduler.schedule(after: deadlines.foregroundClaim) {
    Task { @MainActor [weak self] in
        self?.expireForegroundClaim(for: token)
    }
}

private func expireForegroundClaim(for token: SessionToken) {
    guard sessionToken == token, !settingsClaimed else { return }
    foregroundClaimExpired = true
    hasValidSettings = false
    permissionError = "未能启动该语音请求，请返回键盘重试"
    statusMessage = permissionError ?? ""
    canExit = true
    // Deliberately leave loadedSettings and its App Group file unconsumed.
}
```

Make `startRecording()` async. Refuse to call the engine if the claim already expired. Start the stored immutable request and consume the stream directly on the main actor. The first event must be the matching `.authorizing`; at that event atomically claim the exact file and cancel the 3-second deadline:

```swift
guard hasValidSettings,
      !foregroundClaimExpired,
      !engineStartIssued,
      let request,
      let expected = loadedSettings else { return }
engineStartIssued = true

let stream = await engine.start(request)
for await envelope in stream {
    guard envelope.token == sessionToken else { continue }
    if envelope.event == .authorizing, !settingsClaimed {
        guard let claimed = DarwinBridge.readAndConsumeDictationSettings(
            expectedSession: request.token.rawValue
        ), claimed == expected else {
            foregroundClaimTask?.cancel()
            permissionError = "该语音请求已由另一入口处理，请返回键盘重试"
            statusMessage = permissionError ?? ""
            canExit = true
            await engine.cancel(token: request.token)
            return
        }
        settingsClaimed = true
        foregroundClaimTask?.cancel()
        foregroundClaimTask = nil
    } else if !settingsClaimed {
        permissionError = "语音会话握手失败，请返回键盘重试"
        statusMessage = permissionError ?? ""
        canExit = true
        await engine.cancel(token: request.token)
        return
    }
    apply(envelope.event)
}
```

This is the foreground-host acknowledgement boundary: before it, the request is recoverable and unconsumed; after it, exactly one engine owns it. Set `engineStartIssued` synchronously before the first `await`; a repeated `.onAppear` or button callback therefore cannot create another engine generation or stream consumer. Map authorizing/preparing to existing connecting copy, listening to the current recording visuals/partial, processing to current processing visuals, completed to done/dismiss behavior, failed to the existing specific user message, and cancelled to dismissal without a fabricated error result. On a terminal event, clear the stored request before clearing `engineStartIssued`, so an appearance after completion cannot restart it. Claim failure, claim timeout, an unexpectedly closed nonterminal stream, and `cleanup()` may clear the flag only after cancelling/ending the matching attempt. Make `stopRecording()` and `cancelRecording()` async and have each await exactly one matching engine command; button closures invoke them in one `Task`. `cleanup()` cancels the claim task and cancels the engine only when this model successfully claimed the request.

Delete every `AVAudioEngine`, `SFSpeechRecognizer`, request/task, local generation, silence/finalization timer, permission request, audio notification observer, cleanup, and direct `DarwinBridge.writeTranscription/writeError` call from this file. After the edit:

```bash
rg -n "AVAudioEngine|SFSpeech|installTap|writeTranscription|writeError" VoiceInputApp/DictationView.swift
```

Expected: no matches.

- [ ] **Step 4: Preserve ordinary pending presentation and inject one environment**

Move `presentPendingDictationIfNeeded` into the coordinator as an internal, testable method:

```swift
func enqueuePendingIfAvailable() {
    guard let pending = DarwinBridge.peekPendingDictationSettings() else { return }
    enqueue(session: pending.session, url: nil)
}
```

Call `coordinator.enqueuePendingIfAvailable()` on app appearance and whenever `scenePhase` becomes active. This is the normal manual-open route and must not depend on `onOpenURL`; retain `onOpenURL` only for genuine user/system deep links.

Give `DictationView` an initializer that constructs its `StateObject` with the supplied engine, scheduler, and deadlines, defaulting to the shared engine and production timing. In `VoiceInputApp`, pass `DictationSessionEnvironment.shared.engine` to every full-screen dictation presentation. In `.onAppear`, call `loadSettings` and immediately launch `Task { await viewModel.startRecording() }`; remove the untracked 0.3-second `DispatchQueue.asyncAfter`. Add a test-visible identity assertion that `BackgroundDictationManager.shared.engineIdentity` and the foreground default both point to this same actor; the identity accessor may expose only `ObjectIdentifier`, never the engine's mutable state.

- [ ] **Step 5: Run both adapter contracts and enforce one Apple implementation**

Run:

```bash
xcodebuild test \
  -project VoType.xcodeproj \
  -scheme VoTypeTests \
  -destination "platform=iOS Simulator,id=$SIM_ID" \
  CODE_SIGNING_ALLOWED=NO \
  CURRENT_PROJECT_VERSION="$PLAN_BUILD_NUMBER" \
  -only-testing:VoTypeTests/DictationViewModelTests \
  -only-testing:VoTypeTests/DictationCoordinatorTests \
  -only-testing:VoTypeTests/BackgroundDictationManagerTests \
  -only-testing:VoTypeTests/DictationSessionEngineTests \
  -derivedDataPath ./slice_a_test_build
test "$(rg -l 'installTap' VoiceInputApp | wc -l | tr -d ' ')" = "1"
test "$(rg -l 'SFSpeechAudioBufferRecognitionRequest' VoiceInputApp | wc -l | tr -d ' ')" = "1"
```

Expected: tests PASS and both source-count assertions PASS, with the sole matches in `VoiceInputApp/AppleDictationAdapters.swift`.

- [ ] **Step 6: Commit the foreground migration**

```bash
git add VoiceInputApp/DictationView.swift VoiceInputApp/VoiceInputApp.swift VoTypeTests/DictationViewModelTests.swift VoTypeTests/DictationCoordinatorTests.swift VoTypeTests/DictationSessionTestDoubles.swift
git commit -m "refactor: route foreground dictation through engine"
```

---

### Task 8: Remove Unsupported App Launching and Hold Manual Results

**Files:**
- Create: `Shared/KeyboardResultDispositionPolicy.swift`
- Create: `Shared/DictationHotAckCoordinator.swift`
- Create: `KeyboardExtension/HeldResultActionView.swift`
- Create: `VoTypeTests/KeyboardResultDispositionPolicyTests.swift`
- Create: `VoTypeTests/DictationHotAckCoordinatorTests.swift`
- Create: `scripts/verify_distribution_keyboard_launch.sh`
- Modify: `Shared/DarwinBridge.swift`
- Modify: `Shared/DictationLaunchPolicy.swift`
- Modify: `Shared/KeyboardSessionRecovery.swift`
- Modify: `KeyboardExtension/KeyboardViewController.swift:35-59, 1236-1405, 1434-1451, 1580-1876`
- Modify: `VoTypeTests/DictationLaunchPolicyTests.swift`
- Modify: `VoTypeTests/DictationCoordinatorTests.swift`
- Modify: `VoTypeTests/BackgroundDictationManagerTests.swift`
- Modify: `VoTypeTests/KeyboardSessionRecoveryTests.swift`
- Modify: `VoTypeTests/DictationConstantsTests.swift`
- Modify: `.github/workflows/build.yml`

**Interfaces:**
- Consumes: `EditPlan`, App Group request/result APIs, current context digests, PiP readiness, and the 1.2-second acknowledgement deadline.
- Produces: launch actions with no app-open case, an injected/testable hot-ack timer, persisted `.inPlace`/`.manualOpen` recovery mode, pre-consume and post-consume result validation, explicit held-result UI, and a CI source gate.

- [ ] **Step 1: Rewrite launch-policy tests to require truthful manual recovery**

Replace the old automatic-open assertions with:

```swift
func testFreshStandbyStartsInPlace() {
    XCTAssertEqual(
        DictationLaunchPolicy.initialAction(canStartInPlace: true),
        .requestInPlace
    )
}

func testColdStateShowsManualRecoveryImmediately() {
    XCTAssertEqual(
        DictationLaunchPolicy.initialAction(canStartInPlace: false),
        .showManualRecovery
    )
}

func testHotPathShowsManualRecoveryAtOnePointTwoSeconds() {
    XCTAssertEqual(
        DictationLaunchPolicy.actionAfterNoResponse(
            elapsed: DictationLaunchPolicy.inPlaceResponseDeadline - 0.01,
            initialAction: .requestInPlace
        ),
        .wait
    )
    XCTAssertEqual(
        DictationLaunchPolicy.actionAfterNoResponse(
            elapsed: DictationLaunchPolicy.inPlaceResponseDeadline,
            initialAction: .requestInPlace
        ),
        .showManualRecovery
    )
}
```

Create `VoTypeTests/DictationHotAckCoordinatorTests.swift` and verify the production timeout integration through an injected scheduler, not only through a pure elapsed-time function:

```swift
@MainActor
func testHotAcknowledgementCancelsOnePointTwoSecondFallback() {
    let scheduler = RecordingKeyboardLaunchScheduler()
    let coordinator = DictationHotAckCoordinator(scheduler: scheduler)
    let token = SessionToken()
    var timedOutTokens: [SessionToken] = []

    coordinator.arm(token: token) { timedOutTokens.append($0) }
    XCTAssertEqual(scheduler.scheduledIntervals, [1.2])
    XCTAssertTrue(coordinator.acknowledge(token: token))
    scheduler.fireAll()

    XCTAssertTrue(timedOutTokens.isEmpty)
}

@MainActor
func testHotTimeoutMarksOnlyTheArmedTokenForManualRecovery() {
    let scheduler = RecordingKeyboardLaunchScheduler()
    let coordinator = DictationHotAckCoordinator(scheduler: scheduler)
    let token = SessionToken()
    var timedOutTokens: [SessionToken] = []

    coordinator.arm(token: token) { timedOutTokens.append($0) }
    XCTAssertFalse(coordinator.acknowledge(token: SessionToken()))
    scheduler.fireAll()
    scheduler.fireAll()

    XCTAssertEqual(timedOutTokens, [token])
    XCTAssertFalse(coordinator.acknowledge(token: token))
}
```

The test file's `@MainActor RecordingKeyboardLaunchScheduler` stores scheduled intervals and cancellable closures; `fireAll()` invokes only uncancelled tasks. Its task fake implements `KeyboardLaunchScheduledTask.cancel()` with an `isCancelled` flag.

- [ ] **Step 2: Write recovery/disposition tests before changing the keyboard**

Extend `KeyboardSessionRecoveryTests` with these exact cases:

```swift
func testLegacySnapshotDefaultsToManualOpen() throws {
    let session = UUID().uuidString
    let json = """
    {"session":"\(session)","contextBeforeDigest":"a","contextAfterDigest":"b","selectedTextDigest":"c","hasContextEvidence":true,"timestamp":100}
    """
    defaults.set(Data(json.utf8), forKey: "keyboardSessionRecovery.v1")
    let snapshot = try XCTUnwrap(
        KeyboardSessionRecoveryStore.load(now: 101, defaults: defaults)
    )
    XCTAssertEqual(snapshot.launchMode, .manualOpen)
}

func testInPlaceSnapshotRoundTripsFingerprintWithoutPlainText() throws {
    let before = "private before"
    let after = "private after"
    let selected = "private selection"
    let snapshot = try XCTUnwrap(
        KeyboardSessionRecoveryStore.save(
            session: UUID().uuidString,
            launchMode: .inPlace,
            contextBefore: before,
            contextAfter: after,
            selectedText: selected,
            timestamp: 100,
            defaults: defaults
        )
    )
    let data = try XCTUnwrap(defaults.data(forKey: "keyboardSessionRecovery.v1"))
    let stored = String(decoding: data, as: UTF8.self)
    XCTAssertEqual(snapshot.launchMode, .inPlace)
    XCTAssertFalse(snapshot.contextFingerprint.isEmpty)
    XCTAssertFalse(stored.contains(before))
    XCTAssertFalse(stored.contains(after))
    XCTAssertFalse(stored.contains(selected))
}

func testMarkManualOpenChangesOnlyMatchingSession() throws {
    let session = UUID().uuidString
    _ = KeyboardSessionRecoveryStore.save(
        session: session,
        launchMode: .inPlace,
        contextBefore: "before",
        contextAfter: "after",
        selectedText: nil,
        defaults: defaults
    )
    XCTAssertFalse(
        KeyboardSessionRecoveryStore.markManualOpen(
            session: UUID().uuidString,
            defaults: defaults
        )
    )
    XCTAssertTrue(
        KeyboardSessionRecoveryStore.markManualOpen(
            session: session,
            defaults: defaults
        )
    )
    XCTAssertEqual(
        KeyboardSessionRecoveryStore.load(defaults: defaults)?.launchMode,
        .manualOpen
    )
}
```

Create `KeyboardResultDispositionPolicyTests.swift`:

```swift
func testOnlyCurrentHotNondestructiveSessionCanAutoInsert() {
    XCTAssertEqual(
        KeyboardResultDispositionPolicy.decide(
            launchMode: .inPlace,
            belongsToCurrentExtensionInstance: true,
            hasContextEvidence: true,
            contextMatches: true,
            operation: .insertAtCursor,
            requiresConfirmation: false
        ),
        .autoInsert
    )
}

func testManualRecreatedEmptyChangedAndDestructiveCasesAlwaysHold() {
    let cases: [(KeyboardSessionLaunchMode, Bool, Bool, Bool, EditOperation, Bool)] = [
        (.manualOpen, true, true, true, .insertAtCursor, false),
        (.inPlace, false, true, true, .insertAtCursor, false),
        (.inPlace, true, false, true, .insertAtCursor, false),
        (.inPlace, true, true, false, .insertAtCursor, false),
        (.inPlace, true, true, true, .replaceSelection, true),
        (.inPlace, true, true, true, .deleteSelection, true),
        (.inPlace, true, true, true, .previewOnly, true)
    ]
    for value in cases {
        XCTAssertEqual(
            KeyboardResultDispositionPolicy.decide(
                launchMode: value.0,
                belongsToCurrentExtensionInstance: value.1,
                hasContextEvidence: value.2,
                contextMatches: value.3,
                operation: value.4,
                requiresConfirmation: value.5
            ),
            .hold
        )
    }
}
```

Add pre-consume/post-consume validation cases in the same policy test file:

```swift
func testHeldReplaceRequiresSameTokenFingerprintContextAndLiveSelection() {
    let token = SessionToken()
    let plan = EditPlan(
        intent: .rewrite,
        operation: .replaceSelection,
        text: "新文本",
        expectedContextFingerprint: "fingerprint",
        requiresConfirmation: true
    )
    XCTAssertEqual(
        KeyboardHeldEditValidator.decide(
            plan: plan,
            previewedToken: token,
            heldToken: token,
            snapshotToken: token,
            snapshotFingerprint: "fingerprint",
            hasContextEvidence: true,
            contextMatches: true,
            currentSelectedText: "旧文本"
        ),
        .replaceSelection("新文本")
    )

    let rejectedCases: [(SessionToken, SessionToken?, String?, Bool, Bool, String?)] = [
        (SessionToken(), token, "fingerprint", true, true, "旧文本"),
        (token, SessionToken(), "fingerprint", true, true, "旧文本"),
        (token, token, "changed", true, true, "旧文本"),
        (token, token, "fingerprint", false, true, "旧文本"),
        (token, token, "fingerprint", true, false, "旧文本"),
        (token, token, "fingerprint", true, true, nil),
        (token, token, "fingerprint", true, true, "")
    ]
    for value in rejectedCases {
        XCTAssertEqual(
            KeyboardHeldEditValidator.decide(
                plan: plan,
                previewedToken: token,
                heldToken: value.0,
                snapshotToken: value.1,
                snapshotFingerprint: value.2,
                hasContextEvidence: value.3,
                contextMatches: value.4,
                currentSelectedText: value.5
            ),
            .reject
        )
    }
}

func testLegacyPreviewCanOnlyBecomeExplicitInsertion() {
    let token = SessionToken()
    let plan = EditPlan(
        intent: .rewrite,
        operation: .previewOnly,
        text: "旧版结果",
        expectedContextFingerprint: nil,
        requiresConfirmation: true
    )
    XCTAssertEqual(
        KeyboardHeldEditValidator.decide(
            plan: plan,
            previewedToken: token,
            heldToken: token,
            snapshotToken: nil,
            snapshotFingerprint: nil,
            hasContextEvidence: false,
            contextMatches: false,
            currentSelectedText: nil
        ),
        .insertAtCursor("旧版结果")
    )
}

func testConsumedPayloadMustExactlyMatchPreviewedPayload() {
    let token = SessionToken()
    let previewed = DictationIPCResult(
        status: .completed,
        text: "结果",
        token: token,
        editPlan: EditPlan(
            intent: .dictate,
            operation: .insertAtCursor,
            text: "结果",
            expectedContextFingerprint: nil,
            requiresConfirmation: false
        ),
        timestamp: 100
    )
    XCTAssertTrue(
        KeyboardHeldEditValidator.consumedResultMatchesPreview(
            previewed: previewed,
            consumed: previewed
        )
    )
    var changed = previewed
    changed = DictationIPCResult(
        status: .completed,
        text: "另一个结果",
        token: token,
        editPlan: previewed.editPlan,
        timestamp: 100
    )
    XCTAssertFalse(
        KeyboardHeldEditValidator.consumedResultMatchesPreview(
            previewed: previewed,
            consumed: changed
        )
    )
}
```

Append an IPC integration regression to `DictationConstantsTests.swift`: commit a completed typed result, peek it, consume it once, assert the consumed value equals the preview, then assert a second `readAndConsumeResult` is `nil` and the receipt exists. This proves an action losing the consume race cannot receive a payload to apply.

Add the hot-timeout handoff regression there as well. The timed-out in-place UUID is never reused: the bridge copies the exact immutable settings to a fresh manual UUID and tombstones the old UUID in one coordinated operation.

```swift
func testHotTimeoutHandoffCreatesFreshPendingRequestAndRejectsOldWrites() throws {
    let oldToken = SessionToken()
    let manualToken = SessionToken()
    let original = DictationSettings(
        language: "zh-CN",
        whisper: true,
        translateEnabled: false,
        translateTarget: "en-US",
        selectedText: "原选区",
        keyboardType: 0,
        session: oldToken.rawValue,
        expectedContextFingerprint: "fingerprint"
    )
    XCTAssertTrue(DarwinBridge.writeDictationSettings(original))

    let outcome = DarwinBridge.handoffDictationSettingsToManual(
        from: oldToken,
        to: manualToken,
        original: original
    )
    guard case .moved(let replacement) = outcome else {
        return XCTFail("Expected a fresh manual request")
    }

    XCTAssertEqual(replacement.session, manualToken.rawValue)
    XCTAssertEqual(replacement.language, original.language)
    XCTAssertEqual(replacement.expectedContextFingerprint, "fingerprint")
    XCTAssertNil(DarwinBridge.peekDictationSettings(expectedSession: oldToken.rawValue))
    XCTAssertEqual(
        DarwinBridge.peekDictationSettings(expectedSession: manualToken.rawValue),
        replacement
    )
    XCTAssertTrue(DarwinBridge.isSessionCancelled(session: oldToken.rawValue))
    XCTAssertEqual(
        DarwinBridge.commit(.failed(.recognition), token: oldToken),
        .cancelled
    )
}
```

Extend `KeyboardSessionRecoveryTests` with a `rebindForManualHandoff` case: save an `.inPlace` snapshot, rebind it from the old token to a fresh token, and assert `.manualOpen`, all three component digests, `hasContextEvidence`, and `contextFingerprint` are unchanged while only session/timestamp/mode change.

Finally extract this file-private helper in `DictationCoordinatorTests.swift` and add the full no-deep-link recovery chain:

```swift
private func makeSettings(token: SessionToken) -> DictationSettings {
    DictationSettings(
        language: "zh-CN",
        whisper: false,
        translateEnabled: false,
        translateTarget: "en-US",
        selectedText: nil,
        keyboardType: 0,
        session: token.rawValue
    )
}
```

```swift
@MainActor
func testHotTimeoutReplacementIsClaimedByNormalForegroundLaunch() async throws {
    let oldToken = SessionToken()
    let manualToken = SessionToken()
    let original = makeSettings(token: oldToken)
    XCTAssertTrue(DarwinBridge.writeDictationSettings(original))
    let outcome = DarwinBridge.handoffDictationSettingsToManual(
        from: oldToken,
        to: manualToken,
        original: original
    )
    guard case .moved = outcome else {
        return XCTFail("Expected manual handoff")
    }

    let coordinator = DictationCoordinator()
    coordinator.enqueuePendingIfAvailable()
    XCTAssertEqual(coordinator.presentation?.id, manualToken.rawValue)

    let runner = RecordingSessionRunner(events: [
        .authorizing,
        .preparing,
        .cancelled
    ])
    let model = DictationViewModel(engine: runner)
    model.loadSettings(from: nil, expectedSession: manualToken.rawValue)
    await model.startRecording()

    let requests = await runner.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.token, manualToken)
    XCTAssertEqual(request.entryPoint, .foreground)
    XCTAssertNil(
        DarwinBridge.peekDictationSettings(
            expectedSession: manualToken.rawValue
        )
    )
    XCTAssertEqual(
        DarwinBridge.commit(.failed(.recognition), token: oldToken),
        .cancelled
    )
}
```

Add this phase-specific regression to `BackgroundDictationManagerTests.swift` so handoff can never degrade to stop semantics:

```swift
@MainActor
func testHotTimeoutSendsCancelWhenOldRunnerIsAlreadyProcessing() async throws {
    let oldToken = SessionToken()
    let manualToken = SessionToken()
    let original = makeStoredSettings(session: oldToken.rawValue)
    let runner = RecordingSessionRunner(
        events: [.preparing, .processing],
        finishesStream: false
    )
    let pip = RecordingPiPStandbyPresenter(isActive: true)
    let manager = BackgroundDictationManager(engine: runner, pip: pip)
    let handling = Task { await manager.handlePendingRequest() }
    await runner.waitForRequestCount(1)
    for _ in 0..<100 where !pip.states.contains(.processing("")) {
        await Task.yield()
    }
    XCTAssertTrue(pip.states.contains(.processing("")))

    guard case .moved = DarwinBridge.handoffDictationSettingsToManual(
        from: oldToken,
        to: manualToken,
        original: original
    ) else {
        await runner.finishOpenStreams()
        await handling.value
        return XCTFail("Expected manual handoff")
    }
    await manager.handleCancelNotification(session: oldToken.rawValue)

    let cancelledTokens = await runner.cancelledTokens
    let stoppedTokens = await runner.stoppedTokens
    XCTAssertEqual(cancelledTokens, [oldToken])
    XCTAssertTrue(stoppedTokens.isEmpty)
    XCTAssertEqual(
        DarwinBridge.commit(.failed(.recognition), token: oldToken),
        .cancelled
    )
    XCTAssertEqual(
        DarwinBridge.peekDictationSettings(
            expectedSession: manualToken.rawValue
        )?.session,
        manualToken.rawValue
    )
    await runner.finishOpenStreams()
    await handling.value
}
```

- [ ] **Step 3: Run the launch/recovery suites and confirm old behavior fails**

Run:

```bash
xcodebuild test \
  -project VoType.xcodeproj \
  -scheme VoTypeTests \
  -destination "platform=iOS Simulator,id=$SIM_ID" \
  CODE_SIGNING_ALLOWED=NO \
  CURRENT_PROJECT_VERSION="$PLAN_BUILD_NUMBER" \
  -only-testing:VoTypeTests/DictationLaunchPolicyTests \
  -only-testing:VoTypeTests/DictationHotAckCoordinatorTests \
  -only-testing:VoTypeTests/KeyboardSessionRecoveryTests \
  -only-testing:VoTypeTests/KeyboardResultDispositionPolicyTests \
  -only-testing:VoTypeTests/DictationConstantsTests \
  -only-testing:VoTypeTests/DictationCoordinatorTests \
  -only-testing:VoTypeTests/BackgroundDictationManagerTests \
  -derivedDataPath ./slice_a_test_build
```

Expected: FAIL because `.openContainingApp`, unsafe legacy defaults, automatic recovery, the injected hot-ack timer, and held-result validation are not yet implemented.

- [ ] **Step 4: Implement launch mode, injected hot acknowledgement, and pure result validation**

Change `DictationLaunchAction` to only `.requestInPlace`, `.wait`, and `.showManualRecovery`. `initialAction(false)` returns `.showManualRecovery`; an unanswered `.requestInPlace` returns `.showManualRecovery` at 1.2 seconds. Remove the obsolete keyboard-side 3-second automatic-open stage. Task 7 separately enforces the foreground host's 3-second claim deadline after the user actually opens VoType.

Create `Shared/DictationHotAckCoordinator.swift` with a main-actor scheduling seam and a Timer-backed production implementation:

```swift
@MainActor
protocol KeyboardLaunchScheduledTask: AnyObject {
    func cancel()
}

@MainActor
protocol KeyboardLaunchScheduling: AnyObject {
    func schedule(
        after interval: TimeInterval,
        action: @escaping () -> Void
    ) -> any KeyboardLaunchScheduledTask
}

@MainActor
final class TimerKeyboardLaunchScheduler: KeyboardLaunchScheduling {
    func schedule(
        after interval: TimeInterval,
        action: @escaping () -> Void
    ) -> any KeyboardLaunchScheduledTask {
        TimerKeyboardLaunchTask(
            timer: Timer.scheduledTimer(
                withTimeInterval: interval,
                repeats: false
            ) { _ in action() }
        )
    }
}

@MainActor
final class DictationHotAckCoordinator {
    private let scheduler: any KeyboardLaunchScheduling
    private var armedToken: SessionToken?
    private var task: (any KeyboardLaunchScheduledTask)?

    init(scheduler: any KeyboardLaunchScheduling) {
        self.scheduler = scheduler
    }

    func arm(
        token: SessionToken,
        onTimeout: @escaping (SessionToken) -> Void
    ) {
        cancel()
        armedToken = token
        task = scheduler.schedule(
            after: DictationLaunchPolicy.inPlaceResponseDeadline
        ) { [weak self] in
            guard let self, self.armedToken == token else { return }
            self.task = nil
            self.armedToken = nil
            onTimeout(token)
        }
    }

    @discardableResult
    func acknowledge(token: SessionToken) -> Bool {
        guard armedToken == token else { return false }
        cancel()
        return true
    }

    func cancel() {
        task?.cancel()
        task = nil
        armedToken = nil
    }
}
```

`TimerKeyboardLaunchTask` is a private `@MainActor` wrapper that invalidates its retained `Timer` from `cancel()` and from `deinit`. The keyboard never creates its own untracked `DispatchQueue.asyncAfter` for this deadline.

Add to `KeyboardSessionRecoverySnapshot`:

```swift
enum KeyboardSessionLaunchMode: String, Codable, Equatable {
    case inPlace
    case manualOpen
}

let launchMode: KeyboardSessionLaunchMode
let contextFingerprint: String

init(
    session: String,
    contextBeforeDigest: String,
    contextAfterDigest: String,
    selectedTextDigest: String,
    hasContextEvidence: Bool,
    timestamp: TimeInterval,
    launchMode: KeyboardSessionLaunchMode,
    contextFingerprint: String
) {
    self.session = session
    self.contextBeforeDigest = contextBeforeDigest
    self.contextAfterDigest = contextAfterDigest
    self.selectedTextDigest = selectedTextDigest
    self.hasContextEvidence = hasContextEvidence
    self.timestamp = timestamp
    self.launchMode = launchMode
    self.contextFingerprint = contextFingerprint
}
```

Use these coding keys and safe defaults so any snapshot written before Slice A becomes manual-only:

```swift
private enum CodingKeys: String, CodingKey {
    case session
    case contextBeforeDigest
    case contextAfterDigest
    case selectedTextDigest
    case hasContextEvidence
    case timestamp
    case launchMode
    case contextFingerprint
}

init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    session = try container.decode(String.self, forKey: .session)
    contextBeforeDigest = try container.decode(String.self, forKey: .contextBeforeDigest)
    contextAfterDigest = try container.decode(String.self, forKey: .contextAfterDigest)
    selectedTextDigest = try container.decode(String.self, forKey: .selectedTextDigest)
    hasContextEvidence = try container.decode(Bool.self, forKey: .hasContextEvidence)
    timestamp = try container.decode(TimeInterval.self, forKey: .timestamp)
    launchMode = try container.decodeIfPresent(
        KeyboardSessionLaunchMode.self,
        forKey: .launchMode
    ) ?? .manualOpen
    contextFingerprint = try container.decodeIfPresent(
        String.self,
        forKey: .contextFingerprint
    ) ?? KeyboardSessionRecoveryStore.combineDigests(
        contextBeforeDigest,
        contextAfterDigest,
        selectedTextDigest
    )
}
```

`save` requires an explicit launch mode and computes `contextFingerprint` as `SHA256("beforeDigest|afterDigest|selectedDigest")`, never from persisted plain text. `markManualOpen(session:)` loads the matching snapshot, creates a copy with `.manualOpen`, encodes it with `JSONEncoder`, and replaces only the same storage key. Add `rebindForManualHandoff(from:to:timestamp:)`: it succeeds only when the stored snapshot matches the source token, copies the existing digests/evidence/fingerprint to the fresh token, changes mode to `.manualOpen`, and atomically replaces the one defaults value.

Update every pre-existing `KeyboardSessionRecoveryStore.save` call in `KeyboardSessionRecoveryTests` to pass `launchMode: .manualOpen`; only the new active-hot test passes `.inPlace`.

In `Shared/DarwinBridge.swift`, add:

```swift
enum DictationManualHandoffOutcome: Equatable {
    case moved(DictationSettings)
    case alreadyTerminal
    case failed
}

static func handoffDictationSettingsToManual(
    from source: SessionToken,
    to replacement: SessionToken,
    original: DictationSettings,
    timestamp: TimeInterval = Date().timeIntervalSince1970
) -> DictationManualHandoffOutcome
```

Implement it under a new `withTwoSessionLocks` helper that acquires the source and replacement lock URLs in lexicographically sorted token order through one `NSFileCoordinator` two-item write coordination while holding the existing process-local `ioLock`. The body must enforce all of these rules in order:

1. Source and replacement differ, `original.session == source.rawValue`, both tokens are already validated, and `timestamp > 0`.
2. If the source has a terminal receipt or result, return `.alreadyTerminal` without writing or deleting anything.
3. If the source is already cancelled, or any settings/result/receipt/cancellation file exists for the fresh replacement UUID, return `.failed`.
4. Construct replacement settings by copying language, whisper, translation, selection, keyboard type, and `expectedContextFingerprint`; set only `session = replacement.rawValue` and `timestamp = max(timestamp, original.timestamp.nextUp)`.
5. Write the replacement settings first. Then write the source cancellation tombstone. If the second write fails, remove the just-written replacement settings before returning `.failed`.
6. Remove source settings/live/result only after both writes succeed and return `.moved(replacementSettings)`. Outside the coordinated body, post the source-scoped live-state notification so the old adapter observes cancellation.

The old token is deliberately tombstoned rather than reused: any late Speech/terminal write is rejected, while the new token remains discoverable by ordinary foreground pending lookup. This helper never creates a terminal receipt.

Create `Shared/KeyboardResultDispositionPolicy.swift`:

```swift
enum KeyboardResultDisposition: Equatable {
    case autoInsert
    case hold
}

enum KeyboardResultDispositionPolicy {
    static func decide(
        launchMode: KeyboardSessionLaunchMode,
        belongsToCurrentExtensionInstance: Bool,
        hasContextEvidence: Bool,
        contextMatches: Bool,
        operation: EditOperation,
        requiresConfirmation: Bool
    ) -> KeyboardResultDisposition {
        guard launchMode == .inPlace,
              belongsToCurrentExtensionInstance,
              hasContextEvidence,
              contextMatches,
              operation == .insertAtCursor,
              !requiresConfirmation else { return .hold }
        return .autoInsert
    }
}
```

In the same file add a pure validation result and validator. The validator accepts already-snapshotted facts; it never reads the text proxy, clock, defaults, or App Group itself:

```swift
enum HeldEditApplication: Equatable {
    case insertAtCursor(String)
    case replaceSelection(String)
    case deleteSelection
    case reject
}

enum KeyboardHeldEditValidator {
    static func decide(
        plan: EditPlan,
        previewedToken: SessionToken,
        heldToken: SessionToken,
        snapshotToken: SessionToken?,
        snapshotFingerprint: String?,
        hasContextEvidence: Bool,
        contextMatches: Bool,
        currentSelectedText: String?
    ) -> HeldEditApplication {
        guard previewedToken == heldToken else { return .reject }
        switch plan.operation {
        case .insertAtCursor, .previewOnly:
            return plan.text.isEmpty ? .reject : .insertAtCursor(plan.text)
        case .replaceSelection:
            guard plan.requiresConfirmation,
                  snapshotToken == previewedToken,
                  hasContextEvidence,
                  contextMatches,
                  let expected = plan.expectedContextFingerprint,
                  expected == snapshotFingerprint,
                  let currentSelectedText,
                  !currentSelectedText.isEmpty,
                  !plan.text.isEmpty else { return .reject }
            return .replaceSelection(plan.text)
        case .deleteSelection:
            guard plan.requiresConfirmation,
                  snapshotToken == previewedToken,
                  hasContextEvidence,
                  contextMatches,
                  let expected = plan.expectedContextFingerprint,
                  expected == snapshotFingerprint,
                  let currentSelectedText,
                  !currentSelectedText.isEmpty else { return .reject }
            return .deleteSelection
        }
    }

    static func consumedResultMatchesPreview(
        previewed: DictationIPCResult,
        consumed: DictationIPCResult
    ) -> Bool {
        previewed == consumed
    }
}
```

- [ ] **Step 5: Remove all keyboard-side host launch calls**

In `KeyboardViewController`, add `private lazy var hotAckCoordinator = DictationHotAckCoordinator(scheduler: TimerKeyboardLaunchScheduler())` and remove `darwinFallbackTimer`. In `launchDictation`, compute readiness before saving recovery state. Save `.inPlace` only for fresh readiness; otherwise save `.manualOpen`. For `.requestInPlace`, arm the coordinator and then post `requestStartDictation`:

```swift
hotAckCoordinator.arm(token: token) { [weak self] expiredToken in
    self?.handoffTimedOutHotRequest(expiredToken)
}
DarwinBridge.postNotification(DarwinNotificationName.requestStartDictation)
```

Implement the timeout as a real ownership handoff, not only a label change:

```swift
private func handoffTimedOutHotRequest(_ oldToken: SessionToken) {
    guard currentSessionId == oldToken.rawValue,
          isWaitingForResult,
          let original = currentDictationSettings,
          original.session == oldToken.rawValue else { return }

    let manualToken = SessionToken()
    switch DarwinBridge.handoffDictationSettingsToManual(
        from: oldToken,
        to: manualToken,
        original: original
    ) {
    case .moved(let replacement):
        _ = KeyboardSessionRecoveryStore.rebindForManualHandoff(
            from: oldToken,
            to: manualToken
        )
        DarwinBridge.postSessionNotification(
            base: DarwinNotificationName.requestCancelDictation,
            session: oldToken.rawValue
        )
        finishWaitingState()
        currentSessionId = manualToken.rawValue
        currentDictationSettings = replacement
        currentExtensionSessionToken = nil
        isWaitingForResult = true
        _ = configureSessionObservers(for: manualToken.rawValue)
        startResultTimeout(for: manualToken.rawValue, interval: 65)
        startLiveStatePolling(for: manualToken.rawValue)
        showManualOpenFallback(sessionId: manualToken.rawValue)

    case .alreadyTerminal:
        _ = KeyboardSessionRecoveryStore.markManualOpen(
            session: oldToken.rawValue
        )
        currentExtensionSessionToken = nil
        processPendingResult()

    case .failed:
        currentExtensionSessionToken = nil
        liveTextLabel.text = "无法安全切换到前台，请点麦克风重试"
        updateQuickTypeStatus(liveTextLabel.text ?? "语音输入", phase: nil)
    }
}
```

The `.moved` outcome is the only branch that shows “请从主屏幕打开 VoType，返回后继续”. It first guarantees a fresh pending request and tombstones the old token, then sends the dedicated cancel command so the old App-side engine terminates even if already processing. Never reuse `requestStopDictation` for this handoff because stop during processing is intentionally a no-op. A late `dictationStarted` for the old UUID fails the existing `currentSessionId` guard and `hotAckCoordinator.acknowledge`, so it cannot restore hot mode or automatic insertion. `.failed` keeps a visible retry path and never claims that manual recovery is ready.

`onDictationStarted` must parse the notification session as `SessionToken` and call `hotAckCoordinator.acknowledge(token:)` before changing UI state. `onDictationFailed`, cancellation, result completion, reset, and controller teardown call `hotAckCoordinator.cancel()`. A terminal failure clears `currentExtensionSessionToken` and shows the failure with explicit “点麦克风重试” guidance; it never claims that a pending manual request exists or schedules an automatic retry. Explicit Retry snapshots the current field into a new UUID, binds observers/current session to it, and uses the ordinary launch policy; after PiP readiness was disabled this is `.manualOpen` and its result is held. Consume/discard only the old error payload, retaining its receipt. For a cold request that was actually saved, show “请从主屏幕打开 VoType，返回后继续” immediately and do not arm a timer.

Add a retry regression proving the new UUID differs, the old error cannot reappear in the new session, late old commits remain blocked, and the replacement is bound as a held manual result. This is distinct from the existing nonterminal 1.2-second hot handoff regression.

Add `private var currentExtensionSessionToken: SessionToken?` and `private var currentDictationSettings: DictationSettings?`. Assign both only when this live controller creates the request; retain the immutable settings until terminal cleanup so a consumed hot request can be moved to a new manual UUID. Never set `currentExtensionSessionToken` from `restoreSession`; clear it after insert, copy, discard, cancel, or timeout. Pass the saved `contextFingerprint` into `DictationSettings.expectedContextFingerprint`:

```swift
let token = SessionToken()
currentExtensionSessionToken = token
let launchMode: KeyboardSessionLaunchMode = DarwinBridge.canStartInPlace()
    ? .inPlace
    : .manualOpen
recoveredSnapshot = KeyboardSessionRecoveryStore.save(
    session: token.rawValue,
    launchMode: launchMode,
    contextBefore: textDocumentProxy.documentContextBeforeInput,
    contextAfter: textDocumentProxy.documentContextAfterInput,
    selectedText: selectedTextBeforeRecording
)
let settings = DictationSettings(
    language: LanguageManager.shared.currentLanguage.id,
    whisper: isWhisperMode,
    translateEnabled: TranslationManager.shared.translationEnabled,
    translateTarget: TranslationManager.shared.targetLanguageID,
    selectedText: selectedTextBeforeRecording,
    keyboardType: pendingKbType,
    session: token.rawValue,
    expectedContextFingerprint: recoveredSnapshot?.contextFingerprint
)
currentDictationSettings = settings
```

Delete `requestContainingAppOpen`, `openURLThroughResponderChain`, `darwinFallbackTimer`, every `extensionContext.open`, every `UIApplication` host-open call, every `NSSelectorFromString("openURL:")`, and every delayed responder retry from `KeyboardExtension`. `onDictationFailed` must expose explicit retry without attempting another launch or promising that a terminal UUID can be resumed.

Update readiness copy from “VoType 将短暂打开” to “请手动打开 VoType 后继续”. Do not remove `VoiceInputApp.onOpenURL`; it remains a safe legacy/user-deep-link receiver, not a keyboard launch path.

- [ ] **Step 6: Apply `EditPlan` only after prevalidation**

Before `readAndConsumeResult`, inspect the pending plan and current recovery snapshot. Parse `pending.session`, `currentHeldSession`, and `snapshot.session` through `SessionToken`; an invalid token holds with an error and never reaches a filesystem or mutation helper. Call `KeyboardResultDispositionPolicy.decide` with `belongsToCurrentExtensionInstance == (currentExtensionSessionToken == previewedToken)`. Any recovered snapshot after extension recreation therefore uses false. Only `.autoInsert` may consume and mutate without the action row, and even that path must compare the consumed payload to the preview before inserting.

For every held result, store its session ID in `private var currentHeldSession: String?` and show `HeldResultActionView` with accessible buttons “插入”, “复制”, and “丢弃”:

- Insert: snapshot current proxy context once, call `KeyboardHeldEditValidator.decide` before consumption, and reject without a receipt if it returns `.reject`; then consume, require the consumed payload to exactly equal the preview, and synchronously apply the prevalidated action on the same main-thread turn.
- Copy: consume only the currently previewed session, require exact preview/consumed identity, set `UIPasteboard.general.string` to nonempty plan text, and perform no document mutation.
- Discard: consume only the currently previewed session and ignore the returned content; this creates the receipt and blocks a late duplicate.

Create the action row as a small UIKit component whose only responsibility is forwarding explicit taps:

```swift
import UIKit

final class HeldResultActionView: UIStackView {
    var onInsert: (() -> Void)?
    var onCopy: (() -> Void)?
    var onDiscard: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .horizontal
        distribution = .fillEqually
        spacing = 8
        isHidden = true
        translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(makeButton(title: "插入", action: #selector(insertTapped)))
        addArrangedSubview(makeButton(title: "复制", action: #selector(copyTapped)))
        addArrangedSubview(makeButton(title: "丢弃", action: #selector(discardTapped)))
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func makeButton(title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.accessibilityLabel = title
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func insertTapped() { onInsert?() }
    @objc private func copyTapped() { onCopy?() }
    @objc private func discardTapped() { onDiscard?() }
}
```

Add it to `containerView` at the same vertical slot as `symbolBar`; hide `symbolBar` while a held result is active and restore it after any terminal action.

The insert handler performs the complete two-phase check exactly in this order:

```swift
guard let held = currentHeldSession.flatMap(SessionToken.init(rawValue:)),
      let previewed = DarwinBridge.peekResult(expectedSession: held.rawValue),
      let previewedToken = SessionToken(rawValue: previewed.session),
      previewedToken == held,
      let plan = previewed.editPlan else { return }

let snapshotToken = recoveredSnapshot.flatMap {
    SessionToken(rawValue: $0.session)
}
let contextMatches = recoveredSnapshot.map {
    KeyboardSessionRecoveryStore.matches(
        $0,
        contextBefore: textDocumentProxy.documentContextBeforeInput,
        contextAfter: textDocumentProxy.documentContextAfterInput,
        selectedText: textDocumentProxy.selectedText
    )
} ?? false
let application = KeyboardHeldEditValidator.decide(
    plan: plan,
    previewedToken: previewedToken,
    heldToken: held,
    snapshotToken: snapshotToken,
    snapshotFingerprint: recoveredSnapshot?.contextFingerprint,
    hasContextEvidence: recoveredSnapshot?.hasContextEvidence ?? false,
    contextMatches: contextMatches,
    currentSelectedText: textDocumentProxy.selectedText
)
guard application != .reject else {
    showHeldResultMessage("选区或输入位置已变化，未修改原文")
    return
}

guard let consumed = DarwinBridge.readAndConsumeResult(
          expectedSession: held.rawValue
      ),
      KeyboardHeldEditValidator.consumedResultMatchesPreview(
          previewed: previewed,
          consumed: consumed
      ) else {
    showHeldResultMessage("结果已由其他键盘窗口处理")
    return
}

switch application {
case .insertAtCursor(let text):
    textDocumentProxy.insertText(text)
case .replaceSelection(let text):
    textDocumentProxy.deleteBackward()
    textDocumentProxy.insertText(text)
case .deleteSelection:
    textDocumentProxy.deleteBackward()
case .reject:
    assertionFailure("Rejected edit cannot pass the pre-consume guard")
}
```

The automatic non-destructive path uses the same peek → policy → consume → exact-equality sequence before `insertText`. `.previewOnly` can become only an explicit `.insertAtCursor`; it never deletes selection. A required confirmation with missing/changed selection stays held and shows “选区或输入位置已变化，未修改原文”. If another consumer wins after preview, `readAndConsumeResult` returns `nil`; do not mutate, copy, clear a different session, or fabricate a success state. No receipt is created until prevalidation succeeds.

- [ ] **Step 7: Add the distribution source gate**

Create executable `scripts/verify_distribution_keyboard_launch.sh`:

```bash
#!/bin/bash
set -euo pipefail

found=0
while IFS= read -r forbidden; do
  if /usr/bin/grep -REn --include='*.swift' "$forbidden" KeyboardExtension; then
    found=1
  fi
done <<'PATTERNS'
extensionContext[[:space:]]*\??[[:space:]]*\.open
UIApplication([^[:alnum:]_]|$).*\.open
openURL
NSSelectorFromString
sel_registerName
\.perform[[:space:]]*\(
\.responds[[:space:]]*\([[:space:]]*to:
responder[[:space:]]*=[^\n]*\.next
DictationConstants\.buildDictationURL
PATTERNS

if [ "$found" -ne 0 ]; then
  echo "Unsupported keyboard-to-host launch API found" >&2
  exit 1
fi

echo "Keyboard distribution launch gate passed"
```

Run `chmod +x scripts/verify_distribution_keyboard_launch.sh`. The patterns intentionally cover public extension-context opening, `UIApplication.open`, Objective-C selector construction, responder-chain traversal, and rebuilding the host deep link anywhere under the distributed keyboard source—not only today's exact helper names. Add `bash scripts/verify_distribution_keyboard_launch.sh` to `.github/workflows/build.yml` before unit tests and again before the unsigned Release build so every distribution configuration is covered.

- [ ] **Step 8: Run launch, recovery, IPC, and source gates**

Run:

```bash
bash scripts/verify_distribution_keyboard_launch.sh
xcodebuild test \
  -project VoType.xcodeproj \
  -scheme VoTypeTests \
  -destination "platform=iOS Simulator,id=$SIM_ID" \
  CODE_SIGNING_ALLOWED=NO \
  CURRENT_PROJECT_VERSION="$PLAN_BUILD_NUMBER" \
  -only-testing:VoTypeTests/DictationLaunchPolicyTests \
  -only-testing:VoTypeTests/DictationHotAckCoordinatorTests \
  -only-testing:VoTypeTests/KeyboardSessionRecoveryTests \
  -only-testing:VoTypeTests/KeyboardResultDispositionPolicyTests \
  -only-testing:VoTypeTests/DictationSessionModelsTests \
  -only-testing:VoTypeTests/DictationConstantsTests \
  -only-testing:VoTypeTests/DictationCoordinatorTests \
  -only-testing:VoTypeTests/BackgroundDictationManagerTests \
  -derivedDataPath ./slice_a_test_build
```

Expected: source gate PASS and all tests PASS. The result-action UI still requires later signed-device verification in the target apps.

- [ ] **Step 9: Commit the launch and held-result safety slice**

```bash
git add Shared/DarwinBridge.swift Shared/DictationLaunchPolicy.swift Shared/DictationHotAckCoordinator.swift Shared/KeyboardSessionRecovery.swift Shared/KeyboardResultDispositionPolicy.swift KeyboardExtension/KeyboardViewController.swift KeyboardExtension/HeldResultActionView.swift VoTypeTests/DictationLaunchPolicyTests.swift VoTypeTests/DictationHotAckCoordinatorTests.swift VoTypeTests/DictationCoordinatorTests.swift VoTypeTests/BackgroundDictationManagerTests.swift VoTypeTests/KeyboardSessionRecoveryTests.swift VoTypeTests/KeyboardResultDispositionPolicyTests.swift VoTypeTests/DictationConstantsTests.swift scripts/verify_distribution_keyboard_launch.sh .github/workflows/build.yml
git commit -m "fix: use manual recovery for cold dictation"
```

---

### Task 9: Full Regression, Release/Archive Gates, and Truthful Documentation

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `documentation/architecture.md`
- Modify: `documentation/flows.md`
- Modify: `documentation/tests.md`
- Modify: `documentation/first-run-and-recovery.md`
- Modify: `docs/release-checklist.md`

**Interfaces:**
- Consumes: all Slice A implementation and tests, existing UI smoke scheme, and current unsigned Release/archive commands.
- Produces: fresh automated evidence, versioned architecture/flow/recovery documentation, and an explicit external-device boundary.

- [ ] **Step 1: Regenerate the project and run the complete unit suite**

Run:

```bash
xcodegen generate
bash scripts/verify_distribution_keyboard_launch.sh
xcodebuild test \
  -project VoType.xcodeproj \
  -scheme VoTypeTests \
  -destination "platform=iOS Simulator,id=$SIM_ID" \
  CODE_SIGNING_ALLOWED=NO \
  CURRENT_PROJECT_VERSION="$PLAN_BUILD_NUMBER" \
  -derivedDataPath ./slice_a_test_build
```

Expected: `** TEST SUCCEEDED **`; the existing 20-round IPC test, new 50-round engine test, 100-schedule terminal race, both adapter contracts, normal no-deep-link foreground claim, controlled 3-second foreground timeout, controlled 1.2-second hot fallback, legacy decode, losing-consumer guard, and launch source gate all pass.

- [ ] **Step 2: Run simulator UI smoke without claiming device coverage**

Run:

```bash
xcodebuild test \
  -project VoType.xcodeproj \
  -scheme VoTypeUITests \
  -destination "platform=iOS Simulator,id=$SIM_ID" \
  CODE_SIGNING_ALLOWED=NO \
  CURRENT_PROJECT_VERSION="$PLAN_BUILD_NUMBER" \
  -derivedDataPath ./slice_a_ui_test_build
```

Expected: `** TEST SUCCEEDED **`. Record this only as containing-app simulator UI smoke; do not mark keyboard, microphone, Speech, PiP, or cross-app input as device-passed.

- [ ] **Step 3: Build unsigned Release for a generic iOS device**

Run:

```bash
xcodebuild \
  -project VoType.xcodeproj \
  -scheme VoiceInputApp \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  DEVELOPMENT_TEAM="" \
  CURRENT_PROJECT_VERSION="$PLAN_BUILD_NUMBER" \
  -derivedDataPath ./slice_a_release_build \
  build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Produce and inspect the unsigned archive**

Run:

```bash
xcodebuild archive \
  -project VoType.xcodeproj \
  -scheme VoiceInputApp \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -archivePath ./slice_a_archive/VoType.xcarchive \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  DEVELOPMENT_TEAM="" \
  CURRENT_PROJECT_VERSION="$PLAN_BUILD_NUMBER"
test -d ./slice_a_archive/VoType.xcarchive/Products/Applications/VoiceInputApp.app
test -d ./slice_a_archive/VoType.xcarchive/Products/Applications/VoiceInputApp.app/PlugIns/KeyboardExtension.appex
```

Expected: `** ARCHIVE SUCCEEDED **` and both `test -d` checks exit 0.

- [ ] **Step 5: Update architecture, flows, recovery, and test evidence**

Document these exact delivered facts:

- one actor owns permission/audio/Speech/deadline/terminal state;
- one synchronous buffer gate is the only PCM append path;
- foreground and PiP are adapters over the same engine;
- foreground request discovery works without a deep link, peeks before ownership, and claims at `.authorizing` within 3 seconds;
- manual recovery replaces unsupported keyboard-side launching;
- the 1.2-second hot acknowledgement is injected, cancellable, and unit-tested;
- a timed-out consumed hot request moves to a fresh pending manual UUID while the old UUID is tombstoned and stopped;
- manual results are held for insert/copy/discard;
- held edits validate token, context, selection, fingerprint, and consumed-payload identity before mutation;
- legacy destructive payloads fail closed to preview;
- output persistence failure is an in-memory error and never a fabricated completed result;
- simulator, unsigned device build, and archive evidence are automated only.

Every affected document must contain this exact boundary sentence:

```text
Signed physical-device microphone, Apple Speech, PiP lifecycle, extension eviction, and third-party insertion remain EXTERNAL / NOT_RUN for Slice A.
```

In `CHANGELOG.md`, add the unified engine and manual-recovery changes under the existing unreleased section. In `docs/release-checklist.md`, mark only the automated Slice A gates that actually passed; leave TestFlight, signed-device matrix, screenshots, metadata, and App Review unchecked.

- [ ] **Step 6: Run final static and repository checks**

Run:

```bash
test "$(rg -l 'installTap' VoiceInputApp | wc -l | tr -d ' ')" = "1"
test "$(rg -l 'SFSpeechAudioBufferRecognitionRequest' VoiceInputApp | wc -l | tr -d ' ')" = "1"
bash scripts/verify_distribution_keyboard_launch.sh
git diff --check
git status --short
```

Expected: the two ownership assertions exit 0, the forbidden-launch query is empty, `git diff --check` prints nothing, and `git status --short` lists only the intended Slice A documentation changes before the final commit.

- [ ] **Step 7: Commit the verified Slice A documentation**

```bash
git add README.md CHANGELOG.md documentation/architecture.md documentation/flows.md documentation/tests.md documentation/first-run-and-recovery.md docs/release-checklist.md
git commit -m "docs: record slice a verification"
```

- [ ] **Step 8: Record the final evidence without uploading TestFlight**

Run:

```bash
git rev-parse HEAD
git status --short --branch
```

Expected: a clean worktree on the Slice A branch. Record the exact commit SHA and the four fresh command outcomes in `documentation/tests.md`. Stop before any signing, TestFlight, metadata, screenshot, or App Review action.

## Final Review Checklist

- [ ] Every changed production line traces to one Slice A exit criterion.
- [ ] No foreground or background adapter constructs `AVAudioEngine`, `SFSpeechRecognizer`, or a recognition request.
- [ ] The engine reserves terminal state before awaiting persistence and emits one terminal event.
- [ ] Audio append is synchronous and barrier-protected; buffer callbacks create no task.
- [ ] Old token/generation callbacks, deadlines, and Apple events cannot mutate a new session.
- [ ] Foreground may request permissions; in-place mode never does.
- [ ] Ordinary app activation presents an exact pending request without a deep link; settings remain unconsumed until matching `.authorizing`, and a 3-second miss leaves them recoverable with visible failure.
- [ ] Cold and timed-out hot routes instruct manual open within the required bound and never call unsupported launch APIs.
- [ ] The 1.2-second hot acknowledgement timer is tested through its injected scheduler and cancels on only the matching acknowledgement.
- [ ] A hot timeout cannot strand consumed settings: a fresh manual token is pending before the old token is stopped, and late old acknowledgements/results are ignored or rejected.
- [ ] Manual/recreated/empty/destructive results stay held; token/context/selection/fingerprint are prevalidated, the consumed payload must equal the preview, and no receipt is written before prevalidation and explicit action.
- [ ] New result encoding writes `EditPlan`; legacy destructive decoding is non-destructive.
- [ ] Full unit/UI, source gate, unsigned Release, archive contents, and `git diff --check` have fresh evidence.
- [ ] Physical-device and Apple distribution gates remain explicitly `EXTERNAL / NOT_RUN`.
