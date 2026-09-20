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
        let settings = DictationSettings(language: "zh-CN", whisper: false,
            translateEnabled: false, translateTarget: "en-US", selectedText: nil,
            keyboardType: 0, session: token.rawValue)
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
}
