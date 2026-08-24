import XCTest
@testable import VoiceInputApp

final class DictationViewModelTests: XCTestCase {
    private var ipcDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        ipcDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoTypeViewModelTests-\(UUID().uuidString)", isDirectory: true)
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
            try? FileManager.default.removeItem(at: ipcDirectory)
        }
        try super.tearDownWithError()
    }

    private func writeSettings(
        session: String,
        language: String = "zh-CN",
        whisper: Bool = false,
        translateEnabled: Bool = false,
        translateTarget: String = "en-US",
        selectedText: String? = nil,
        keyboardType: Int = 0
    ) {
        XCTAssertTrue(
            DarwinBridge.writeDictationSettings(
                DictationSettings(
                    language: language,
                    whisper: whisper,
                    translateEnabled: translateEnabled,
                    translateTarget: translateTarget,
                    selectedText: selectedText,
                    keyboardType: keyboardType,
                    session: session
                )
            )
        )
    }

    func testLoadSettingsFromURL() async {
        await MainActor.run {
            let session = UUID().uuidString
            writeSettings(session: session, language: "en-US", whisper: true)
            let url = DictationConstants.buildDictationURL(session: session)
            let viewModel = DictationViewModel()
            viewModel.loadSettings(from: url)

            XCTAssertTrue(viewModel.hasValidSettings)
            XCTAssertEqual(viewModel.languageID, "en-US")
            XCTAssertTrue(viewModel.whisperMode)
            XCTAssertFalse(viewModel.translateEnabled)
            XCTAssertEqual(viewModel.translateTarget, "en-US")
            XCTAssertNil(viewModel.selectedText)
            XCTAssertEqual(viewModel.keyboardType, 0)
            XCTAssertEqual(viewModel.sessionId, session)
            XCTAssertEqual(
                DarwinBridge.readLiveState(expectedSession: session)?.phase,
                .starting
            )
        }
    }

    func testLoadSettingsFromNilURL() async {
        await MainActor.run {
            let session = UUID().uuidString
            writeSettings(session: session, language: "ja-JP")
            let viewModel = DictationViewModel()
            viewModel.loadSettings(from: nil)
            XCTAssertTrue(viewModel.hasValidSettings)
            XCTAssertEqual(viewModel.sessionId, session)
            XCTAssertEqual(viewModel.languageID, "ja-JP")
        }
    }

    func testExplicitPresentationSessionCannotConsumeNewerRequest() async {
        await MainActor.run {
            let queuedSession = UUID().uuidString
            let newerSession = UUID().uuidString
            let now = Date().timeIntervalSince1970
            XCTAssertTrue(
                DarwinBridge.writeDictationSettings(
                    DictationSettings(
                        language: "ja-JP",
                        whisper: false,
                        translateEnabled: false,
                        translateTarget: "en-US",
                        selectedText: nil,
                        keyboardType: 0,
                        session: queuedSession,
                        timestamp: now
                    )
                )
            )
            XCTAssertTrue(
                DarwinBridge.writeDictationSettings(
                    DictationSettings(
                        language: "en-US",
                        whisper: false,
                        translateEnabled: false,
                        translateTarget: "zh-CN",
                        selectedText: nil,
                        keyboardType: 0,
                        session: newerSession,
                        timestamp: now + 1
                    )
                )
            )

            let viewModel = DictationViewModel()
            viewModel.loadSettings(
                from: nil,
                expectedSession: queuedSession
            )

            XCTAssertTrue(viewModel.hasValidSettings)
            XCTAssertEqual(viewModel.sessionId, queuedSession)
            XCTAssertEqual(viewModel.languageID, "ja-JP")
            XCTAssertEqual(
                DarwinBridge.peekPendingDictationSettings(now: now + 1)?.session,
                newerSession
            )
        }
    }

    func testLoadSettingsWithSelectedText() async {
        await MainActor.run {
            let session = UUID().uuidString
            writeSettings(
                session: session,
                selectedText: "hello",
                keyboardType: 7
            )
            let url = DictationConstants.buildDictationURL(session: session)
            let viewModel = DictationViewModel()
            viewModel.loadSettings(from: url)

            XCTAssertEqual(viewModel.selectedText, "hello")
            XCTAssertEqual(viewModel.keyboardType, 7)
            XCTAssertEqual(viewModel.sessionId, session)
        }
    }

    func testLoadSettingsWithTranslate() async {
        await MainActor.run {
            let session = UUID().uuidString
            writeSettings(
                session: session,
                translateEnabled: true,
                translateTarget: "en-US"
            )
            let url = DictationConstants.buildDictationURL(session: session)
            let viewModel = DictationViewModel()
            viewModel.loadSettings(from: url)

            XCTAssertTrue(viewModel.translateEnabled)
            XCTAssertEqual(viewModel.translateTarget, "en-US")
            XCTAssertEqual(viewModel.languageID, "zh-CN")
        }
    }

    func testURLCannotSupplySettingsWithoutAppGroupRequest() async {
        await MainActor.run {
            let url = DictationConstants.buildDictationURL(session: UUID().uuidString)
            let viewModel = DictationViewModel()
            viewModel.loadSettings(from: url)

            XCTAssertFalse(viewModel.hasValidSettings)
            XCTAssertEqual(viewModel.sessionId, "")
        }
    }

    func testStopRecordingWithoutStart() async {
        await MainActor.run {
            let viewModel = DictationViewModel()
            viewModel.stopRecording()
        }
    }

    func testCleanupWithoutStart() async {
        await MainActor.run {
            let viewModel = DictationViewModel()
            viewModel.cleanup()
        }
    }
}
