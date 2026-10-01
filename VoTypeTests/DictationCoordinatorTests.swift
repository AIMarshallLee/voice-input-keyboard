import XCTest
@testable import VoiceInputApp

@MainActor
final class DictationCoordinatorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoTypeCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        DarwinBridge.setContainerDirectoryForTesting(directory)
    }

    override func tearDownWithError() throws {
        DarwinBridge.clearIPCFilesForTesting()
        DarwinBridge.resetContainerDirectoryAfterTesting()
        try FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testActiveAppEnqueuesPendingRequestWithoutDeepLinkOrConsumption() async throws {
        let token = SessionToken()
        let settings = makeSettings(token: token)
        XCTAssertTrue(DarwinBridge.writeDictationSettings(settings))
        let coordinator = DictationCoordinator()

        coordinator.enqueuePendingIfAvailable()

        XCTAssertEqual(coordinator.presentation?.id, token.rawValue)
        XCTAssertNil(coordinator.presentation?.url)
        XCTAssertEqual(DarwinBridge.peekDictationSettings(expectedSession: token.rawValue), settings)
        coordinator.enqueuePendingIfAvailable()
        coordinator.presentation = nil
        coordinator.didDismiss()
        try await requireStableCondition("Repeated activation must not queue the same request") {
            coordinator.presentation == nil
        }
    }

    func testNoPendingOrCancelledRequestDoesNotPresent() {
        let coordinator = DictationCoordinator()
        coordinator.enqueuePendingIfAvailable()
        XCTAssertNil(coordinator.presentation)
        let token = SessionToken()
        XCTAssertTrue(DarwinBridge.writeDictationSettings(DictationSettings(language: "zh-CN",
            whisper: false, translateEnabled: false, translateTarget: "en-US",
            selectedText: nil, keyboardType: 0, session: token.rawValue)))
        XCTAssertTrue(DarwinBridge.cancelSession(token.rawValue))
        coordinator.enqueuePendingIfAvailable()
        XCTAssertNil(coordinator.presentation)
    }

    func testHotTimeoutReplacementIsClaimedByNormalForegroundLaunch() async throws {
        let old = SessionToken()
        let manual = SessionToken()
        let original = makeSettings(token: old)
        XCTAssertTrue(DarwinBridge.writeDictationSettings(original))
        guard case .moved = DarwinBridge.handoffDictationSettingsToManual(
            from: old, to: manual, original: original) else {
            return XCTFail("Expected manual handoff")
        }
        let coordinator = DictationCoordinator()
        coordinator.enqueuePendingIfAvailable()
        XCTAssertEqual(coordinator.presentation?.id, manual.rawValue)
        XCTAssertNil(coordinator.presentation?.url)
        let runner = RecordingSessionRunner(events: [.authorizing, .preparing, .cancelled])
        addTeardownBlock { await runner.finishAllStreams() }
        let model = DictationViewModel(engine: runner)
        defer { model.cleanup() }
        model.loadSettings(from: nil, expectedSession: manual.rawValue)
        try await runBoundedOperation("normal foreground claims replacement") { await model.startRecording() }
        let requests = await runner.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.token, manual)
        XCTAssertEqual(request.entryPoint, .foreground)
        XCTAssertNil(DarwinBridge.peekDictationSettings(expectedSession: manual.rawValue))
        XCTAssertEqual(DarwinBridge.commit(.failed(.recognition), token: old), .cancelled)
    }
}

private func makeSettings(token: SessionToken) -> DictationSettings {
    DictationSettings(language: "zh-CN", whisper: false, translateEnabled: false,
        translateTarget: "en-US", selectedText: nil, keyboardType: 0, session: token.rawValue)
}
