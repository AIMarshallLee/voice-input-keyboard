import AVFoundation
import Foundation
import XCTest
@testable import VoiceInputApp

final class AppleDictationAdaptersTests: XCTestCase {
    private var ipcDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        ipcDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleDictationAdaptersTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: ipcDirectory,
            withIntermediateDirectories: true
        )
        DarwinBridge.setContainerDirectoryForTesting(ipcDirectory)
    }

    override func tearDownWithError() throws {
        DarwinBridge.clearIPCFilesForTesting()
        DarwinBridge.resetContainerDirectoryAfterTesting()
        if let ipcDirectory {
            try FileManager.default.removeItem(at: ipcDirectory)
        }
        ipcDirectory = nil
        try super.tearDownWithError()
    }

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
        XCTAssertEqual(
            DictationPermissionDecision.next(
                speech: .denied,
                microphone: .authorized,
                policy: .readOnly
            ),
            .fail(.permissionDenied(.speech))
        )
        XCTAssertEqual(
            DictationPermissionDecision.next(
                speech: .authorized,
                microphone: .authorized,
                policy: .readOnly
            ),
            .proceed
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
        XCTAssertEqual(
            DictationPermissionDecision.next(
                speech: .authorized,
                microphone: .denied,
                policy: .requestIfNeeded
            ),
            .fail(.permissionDenied(.microphone))
        )
        XCTAssertEqual(
            DictationPermissionDecision.next(
                speech: .authorized,
                microphone: .authorized,
                policy: .requestIfNeeded
            ),
            .proceed
        )
    }

    func testPermissionResolverUsesAuthorizedStatesWithoutRequestingPermission() async {
        let speechState = LockedTestBox(DictationAuthorizationState.authorized)
        let microphoneState = LockedTestBox(DictationAuthorizationState.authorized)
        let requests = TestOperationJournal()
        let resolver = AppleDictationPermissionResolver(
            speechAuthorizationState: { speechState.value },
            microphoneAuthorizationState: { microphoneState.value },
            requestSpeechAuthorization: { requests.record("speech") },
            requestMicrophoneAuthorization: { requests.record("microphone") }
        )

        let result = await resolver.authorize(policy: .requestIfNeeded)

        guard case .success = result else {
            XCTFail("Authorized permissions should proceed")
            return
        }
        XCTAssertTrue(requests.entries.isEmpty)
    }

    func testPermissionResolverRequestsOnlyTheMissingForegroundPermission() async {
        let speechState = LockedTestBox(DictationAuthorizationState.authorized)
        let microphoneState = LockedTestBox(DictationAuthorizationState.notDetermined)
        let requests = TestOperationJournal()
        let resolver = AppleDictationPermissionResolver(
            speechAuthorizationState: { speechState.value },
            microphoneAuthorizationState: { microphoneState.value },
            requestSpeechAuthorization: { requests.record("speech") },
            requestMicrophoneAuthorization: {
                requests.record("microphone")
                microphoneState.set(.authorized)
            }
        )

        let result = await resolver.authorize(policy: .requestIfNeeded)

        guard case .success = result else {
            XCTFail("The requested microphone permission should proceed")
            return
        }
        XCTAssertEqual(requests.entries, ["microphone"])
    }

    func testPermissionResolverReadOnlyPolicyDoesNotRequestMissingPermission() async {
        let speechState = LockedTestBox(DictationAuthorizationState.notDetermined)
        let microphoneState = LockedTestBox(DictationAuthorizationState.authorized)
        let requests = TestOperationJournal()
        let resolver = AppleDictationPermissionResolver(
            speechAuthorizationState: { speechState.value },
            microphoneAuthorizationState: { microphoneState.value },
            requestSpeechAuthorization: { requests.record("speech") },
            requestMicrophoneAuthorization: { requests.record("microphone") }
        )

        let result = await resolver.authorize(policy: .readOnly)

        guard case .failure(let failure) = result else {
            XCTFail("Read-only authorization should report the missing permission")
            return
        }
        XCTAssertEqual(failure, .permissionRequiresForeground(.speech))
        XCTAssertTrue(requests.entries.isEmpty)
    }

    func testPermissionResolverCancellationBeforeSpeechRequestSkipsSystemPrompt() async {
        let speechState = LockedTestBox(DictationAuthorizationState.notDetermined)
        let microphoneState = LockedTestBox(DictationAuthorizationState.authorized)
        let requests = TestOperationJournal()
        let resolver = AppleDictationPermissionResolver(
            speechAuthorizationState: {
                withUnsafeCurrentTask { $0?.cancel() }
                return speechState.value
            },
            microphoneAuthorizationState: { microphoneState.value },
            requestSpeechAuthorization: {
                requests.record("speech")
                speechState.set(.authorized)
            },
            requestMicrophoneAuthorization: { requests.record("microphone") }
        )

        _ = await resolver.authorize(policy: .requestIfNeeded)

        XCTAssertTrue(requests.entries.isEmpty)
    }

    func testPermissionResolverCancellationAfterSpeechCallbackSkipsMicrophonePrompt() async {
        let speechState = LockedTestBox(DictationAuthorizationState.notDetermined)
        let microphoneState = LockedTestBox(DictationAuthorizationState.notDetermined)
        let requests = TestOperationJournal()
        let speechCallbackGate = PermissionResultGate()
        let resolver = AppleDictationPermissionResolver(
            speechAuthorizationState: { speechState.value },
            microphoneAuthorizationState: { microphoneState.value },
            requestSpeechAuthorization: {
                requests.record("speech")
                _ = await speechCallbackGate.wait()
                speechState.set(.authorized)
            },
            requestMicrophoneAuthorization: {
                requests.record("microphone")
                microphoneState.set(.authorized)
            }
        )
        let authorization = Task {
            await resolver.authorize(policy: .requestIfNeeded)
        }
        var speechCallbackReleased = false
        defer {
            authorization.cancel()
            if !speechCallbackReleased {
                speechCallbackGate.resume(with: .failure(.interrupted))
            }
        }

        let speechRequestDidStart = (try? await waitUntil("Speech system request", timeout: 1) {
            requests.entries.contains("speech")
        }) != nil
        if !speechRequestDidStart {
            authorization.cancel()
            speechCallbackGate.resume(with: .failure(.interrupted))
            speechCallbackReleased = true
            do {
                try await runBoundedOperation("authorization task completion") {
                    _ = await authorization.value
                }
            } catch {
                XCTFail("Authorization did not finish after releasing the Speech callback: \(error)")
            }
            XCTFail("Speech system request did not start")
            return
        }
        authorization.cancel()
        speechCallbackGate.resume(with: .success(()))
        speechCallbackReleased = true
        do {
            try await runBoundedOperation("authorization task completion") {
                _ = await authorization.value
            }
        } catch {
            XCTFail("Authorization did not finish after releasing the Speech callback: \(error)")
        }

        XCTAssertEqual(requests.entries, ["speech"])
    }

    func testOutputOnlyRemovalWithUnchangedInputDoesNotEmitInputRouteLoss() async {
        let event = await routeChangeEvent(
            inputRouteIdentities: (previous: ["built-in-mic"], current: ["built-in-mic"]),
            expectedFirstEvent: .interruptionBegan
        )

        XCTAssertEqual(event, .interruptionBegan)
    }

    func testOldDeviceUnavailableAfterInputRemovalAndFallbackEmitsInputRouteLoss() async {
        let event = await routeChangeEvent(
            inputRouteIdentities: (previous: ["external-mic"], current: ["built-in-mic"]),
            expectedFirstEvent: .inputRouteLost
        )

        XCTAssertEqual(event, .inputRouteLost)
    }

    func testOldDeviceUnavailableWithoutRouteEvidenceDoesNotInventInputLoss() async {
        let event = await routeChangeEvent(
            inputRouteIdentities: nil,
            expectedFirstEvent: .interruptionBegan
        )

        XCTAssertEqual(event, .interruptionBegan)
    }

    private func routeChangeEvent(
        inputRouteIdentities: (previous: [String], current: [String])?,
        expectedFirstEvent: DictationAudioSystemEvent
    ) async -> DictationAudioSystemEvent? {
        let center = NotificationCenter()
        let eventSource = AppleDictationAudioSystemEventSource(
            notificationCenter: center,
            inputRouteIdentities: { _ in inputRouteIdentities }
        )
        let observedEvent = LockedTestBox<DictationAudioSystemEvent?>(nil)
        let eventReceived = LockedTestBox(false)
        let consumer = Task {
            var iterator = eventSource.events.makeAsyncIterator()
            if let event = await iterator.next() {
                observedEvent.set(event)
                eventReceived.set(true)
            }
        }
        defer { consumer.cancel() }
        center.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [
                AVAudioSessionRouteChangeReasonKey:
                    AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            ]
        )
        center.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.began.rawValue
            ]
        )

        let eventDidArrive = (try? await waitUntil("first audio system event", timeout: 1) {
            eventReceived.value
        }) != nil
        if !eventDidArrive {
            XCTFail("Expected the route or interruption notification to emit an event")
        } else {
            XCTAssertEqual(observedEvent.value, expectedFirstEvent)
        }
        do {
            try await runBoundedOperation("audio event consumer completion") {
                await consumer.value
            }
        } catch {
            XCTFail("Audio event consumer did not finish: \(error)")
        }
        return observedEvent.value
    }

    func testTerminalNotificationNamesOnlyMarkFailuresWhenWritten() {
        let completed = DictationTerminal.completed(
            EditPlan(
                intent: .dictate,
                operation: .insertAtCursor,
                text: "final",
                expectedContextFingerprint: nil,
                requiresConfirmation: false
            )
        )
        let cases: [(DictationTerminal, DictationOutputCommitStatus, [String])] = [
            (
                .failed(.recognition),
                .written,
                [DarwinNotificationName.dictationFailed, DarwinNotificationName.dictationStopped]
            ),
            (completed, .written, [DarwinNotificationName.dictationStopped]),
            (completed, .cancelled, [DarwinNotificationName.dictationStopped]),
            (.failed(.recognition), .cancelled, [DarwinNotificationName.dictationStopped]),
            (.cancelled, .cancelled, [DarwinNotificationName.dictationStopped]),
            (.failed(.recognition), .alreadyTerminal, []),
            (.failed(.recognition), .ioFailure, [])
        ]

        for (terminal, status, expected) in cases {
            XCTAssertEqual(
                DarwinDictationSessionOutput.terminalNotificationNames(
                    for: terminal,
                    status: status
                ),
                expected
            )
        }
    }

    func testTextAdapterMapsDictationAndSelectedEditsSafely() {
        let plain = makeSnapshot(selectedText: nil, voiceEditEnabled: true)
        XCTAssertEqual(
            TextProcessorDictationAdapter.plan(from: .insert("你好。"), snapshot: plain),
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
            TextProcessorDictationAdapter.plan(from: .deleteSelection, snapshot: selected),
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
            TextProcessorDictationAdapter.plan(from: .insert("新文本"), snapshot: selected),
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

        let translated = TextProcessingSnapshot(
            selectedText: nil,
            keyboardType: 0,
            language: "zh-CN",
            translateEnabled: true,
            translateTarget: "en-US",
            voiceEditEnabled: true,
            livePreviewEnabled: true,
            expectedContextFingerprint: "context-digest"
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

    @MainActor
    func testLiveOutputKeepsHighestSequenceAndPersistsHigherSequenceImmediately() async {
        let token = SessionToken()
        let request = makeRequest(token: token)
        let output = DarwinDictationSessionOutput()

        await output.publishLive(liveEnvelope(token: token, sequence: 2, partial: "newer"), request: request)
        await output.publishLive(liveEnvelope(token: token, sequence: 1, partial: "older"), request: request)
        await output.publishLive(liveEnvelope(token: token, sequence: 2, partial: "duplicate"), request: request)

        let afterOlderWrites = DarwinBridge.readLiveState(expectedSession: token.rawValue)
        XCTAssertEqual(afterOlderWrites?.partialTranscript, "newer")

        await output.publishLive(liveEnvelope(token: token, sequence: 3, partial: "immediate"), request: request)
        let afterHigherSequence = DarwinBridge.readLiveState(expectedSession: token.rawValue)
        XCTAssertEqual(afterHigherSequence?.partialTranscript, "immediate")
    }

    @MainActor
    func testLiveOutputRejectsMismatchedEnvelopeToken() async {
        let requestToken = SessionToken()
        let envelopeToken = SessionToken()
        let output = DarwinDictationSessionOutput()
        let request = makeRequest(token: requestToken)

        await output.publishLive(
            liveEnvelope(token: envelopeToken, sequence: 1, partial: "wrong token"),
            request: request
        )

        let requestState = DarwinBridge.readLiveState(expectedSession: requestToken.rawValue)
        let envelopeState = DarwinBridge.readLiveState(expectedSession: envelopeToken.rawValue)
        XCTAssertNil(requestState)
        XCTAssertNil(envelopeState)
    }

    @MainActor
    func testLiveOutputRejectsWritesAfterCommitBegins() async {
        let token = SessionToken()
        let request = makeRequest(token: token)
        let output = DarwinDictationSessionOutput()
        let terminal = DictationTerminal.completed(
            EditPlan(
                intent: .dictate,
                operation: .insertAtCursor,
                text: "final",
                expectedContextFingerprint: nil,
                requiresConfirmation: false
            )
        )

        let status = await output.commit(terminal, token: token)
        XCTAssertEqual(status, .written)

        // Remove the bridge's durable terminal receipt so this asserts the adapter's
        // process-local admission closure rather than the bridge backstop.
        DarwinBridge.clearIPCFilesForTesting()
        await output.publishLive(liveEnvelope(token: token, sequence: 1, partial: "late"), request: request)
        let state = DarwinBridge.readLiveState(expectedSession: token.rawValue)
        XCTAssertNil(state)
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

    private func makeRequest(token: SessionToken) -> DictationSessionRequest {
        DictationSessionRequest(
            token: token,
            entryPoint: .foreground,
            authorizationPolicy: .requestIfNeeded,
            whisper: false,
            processing: makeSnapshot(selectedText: nil, voiceEditEnabled: true)
        )
    }

    private func liveEnvelope(
        token: SessionToken,
        sequence: UInt64,
        partial: String
    ) -> DictationSessionEventEnvelope {
        DictationSessionEventEnvelope(
            token: token,
            sequence: sequence,
            event: .listening(partial: partial)
        )
    }
}
