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
