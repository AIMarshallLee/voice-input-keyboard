import XCTest
@testable import VoiceInputApp

final class DictationConstantsTests: XCTestCase {

    private var ipcDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        ipcDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoTypeTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - URL 构建 (Path B 降级路径)

    func testBuildDictationURL() {
        let session = "5B6D67A5-5C34-4EB8-BB2D-9113A8E7BD18"
        let url = DictationConstants.buildDictationURL(session: session)

        XCTAssertNotNil(url)
        XCTAssertEqual(url?.scheme, "votype")
        XCTAssertEqual(url?.host, "dictation")

        let comps = URLComponents(url: url!, resolvingAgainstBaseURL: false)
        let queryDict = Dictionary(comps?.queryItems?.compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        } ?? [], uniquingKeysWith: { _, last in last })

        XCTAssertEqual(queryDict, ["session": session])
    }

    func testBuildDictationURLRejectsNonUUIDSession() {
        XCTAssertNil(DictationConstants.buildDictationURL(session: "not-a-uuid"))
    }

    // MARK: - DarwinBridge IPC (命名剪贴板)

    func testDarwinBridgeWriteAndReadTranscription() {
        let testText = "这是一段测试语音识别结果"
        let testSession = UUID().uuidString

        DarwinBridge.writeTranscription(testText, session: testSession)

        let result = DarwinBridge.readAndConsumeResult(expectedSession: testSession)
        XCTAssertEqual(result?.transcription, testText)
        XCTAssertEqual(result?.session, testSession)
        XCTAssertNil(result?.error)
    }

    func testDarwinBridgeWriteAndReadError() {
        let testError = "未识别到语音"
        let testSession = UUID().uuidString

        DarwinBridge.writeError(testError, session: testSession)

        let result = DarwinBridge.readAndConsumeResult(expectedSession: testSession)
        XCTAssertNil(result?.transcription)
        XCTAssertEqual(result?.error, testError)
        XCTAssertEqual(result?.session, testSession)
    }

    func testDarwinBridgeReadAfterConsumeReturnsNil() {
        let testText = "测试"
        let testSession = UUID().uuidString

        DarwinBridge.writeTranscription(testText, session: testSession)
        _ = DarwinBridge.readAndConsumeResult(expectedSession: testSession)

        // 第二次读应该返回 nil (剪贴板已被消费清空)
        let result = DarwinBridge.readAndConsumeResult(expectedSession: testSession)
        XCTAssertNil(result)
    }

    func testDarwinBridgeSessionMismatch() {
        let session1 = "session-aaa"
        let session2 = "session-bbb"

        // 写入 session1 的结果
        DarwinBridge.writeTranscription("结果1", session: session1)

        // session2 不匹配时必须拒绝且不能消费 session1 的结果
        XCTAssertNil(DarwinBridge.readAndConsumeResult(expectedSession: session2))
        XCTAssertEqual(DarwinBridge.peekResult()?.session, session1)

        let result = DarwinBridge.readAndConsumeResult(expectedSession: session1)
        XCTAssertEqual(result?.session, session1)
        XCTAssertEqual(result?.transcription, "结果1")
        XCTAssertNil(DarwinBridge.peekResult())
    }

    func testResultsForDifferentSessionsDoNotOverwriteEachOther() {
        let now = Date().timeIntervalSince1970
        let sessionA = UUID().uuidString
        let sessionB = UUID().uuidString
        DarwinBridge.writeTranscription("A", session: sessionA, timestamp: now)
        DarwinBridge.writeTranscription("B", session: sessionB, timestamp: now + 1)

        XCTAssertEqual(DarwinBridge.peekResult(now: now + 1)?.session, sessionB)
        XCTAssertEqual(
            DarwinBridge.readAndConsumeResult(
                expectedSession: sessionB,
                now: now + 1
            )?.transcription,
            "B"
        )
        XCTAssertEqual(
            DarwinBridge.readAndConsumeResult(
                expectedSession: sessionA,
                now: now + 1
            )?.transcription,
            "A"
        )
    }

    func testDiscardRecoveredResultAlsoRemovesOlderResults() {
        let now = Date().timeIntervalSince1970
        let olderSession = UUID().uuidString
        let confirmedSession = UUID().uuidString
        let newerSession = UUID().uuidString
        DarwinBridge.writeTranscription("older", session: olderSession, timestamp: now)
        DarwinBridge.writeTranscription("confirmed", session: confirmedSession, timestamp: now + 1)
        DarwinBridge.writeTranscription("newer", session: newerSession, timestamp: now + 2)

        let confirmed = DarwinBridge.readAndConsumeResult(
            expectedSession: confirmedSession,
            now: now + 2
        )
        DarwinBridge.discardResults(through: confirmed?.timestamp ?? 0, now: now + 2)

        XCTAssertNil(
            DarwinBridge.readAndConsumeResult(
                expectedSession: olderSession,
                now: now + 2
            )
        )
        XCTAssertEqual(
            DarwinBridge.readAndConsumeResult(
                expectedSession: newerSession,
                now: now + 2
            )?.transcription,
            "newer"
        )
    }

    func testSessionNotificationNamesAreScopedAndDeterministic() {
        let sessionA = UUID().uuidString
        let sessionB = UUID().uuidString
        let first = DarwinBridge.sessionNotificationName(
            base: DarwinNotificationName.dictationStarted,
            session: sessionA
        )
        XCTAssertEqual(
            first,
            DarwinBridge.sessionNotificationName(
                base: DarwinNotificationName.dictationStarted,
                session: sessionA
            )
        )
        XCTAssertNotEqual(
            first,
            DarwinBridge.sessionNotificationName(
                base: DarwinNotificationName.dictationStarted,
                session: sessionB
            )
        )
    }

    func testExpiredResultIsRemoved() {
        let now = Date().timeIntervalSince1970
        DarwinBridge.writeTranscription("过期", session: "old", timestamp: now - 301)

        XCTAssertNil(DarwinBridge.peekResult(now: now, maxAge: 300))
        XCTAssertNil(DarwinBridge.readAndConsumeResult(expectedSession: "old", now: now))
    }

    func testDarwinBridgeHeartbeat() {
        // 先访问 HeartbeatTracker 初始化单例(注册 Darwin 通知观察者)
        _ = DarwinBridge.isMainAppAlive(threshold: 0.01)

        // 发送心跳
        DarwinBridge.writeHeartbeat()

        // 给主线程时间处理 Darwin 通知回调
        let expectation = XCTestExpectation(description: "heartbeat received")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        // 心跳应该存在且新鲜
        let age = DarwinBridge.heartbeatAge()
        XCTAssertLessThan(age, 2.0, "Heartbeat age should be less than 2 seconds")
        XCTAssertTrue(DarwinBridge.isMainAppAlive(threshold: 3.0))
    }

    func testDarwinBridgeDictationSettings() {
        let settings = DictationSettings(
            language: "zh-CN",
            whisper: true,
            translateEnabled: false,
            translateTarget: "en",
            selectedText: "选中文本",
            keyboardType: 1,
            session: "test-settings-session"
        )

        DarwinBridge.writeDictationSettings(settings)

        let pending = DarwinBridge.peekPendingDictationSettings()
        XCTAssertEqual(pending?.session, "test-settings-session")

        let read = DarwinBridge.readAndConsumeDictationSettings(
            expectedSession: "test-settings-session"
        )
        XCTAssertNotNil(read)
        XCTAssertEqual(read?.language, "zh-CN")
        XCTAssertEqual(read?.whisper, true)
        XCTAssertEqual(read?.translateEnabled, false)
        XCTAssertEqual(read?.translateTarget, "en")
        XCTAssertEqual(read?.selectedText, "选中文本")
        XCTAssertEqual(read?.keyboardType, 1)
        XCTAssertEqual(read?.session, "test-settings-session")
        XCTAssertNil(DarwinBridge.peekPendingDictationSettings())
    }

    func testExpiredSettingsAreRemoved() {
        let now = Date().timeIntervalSince1970
        let settings = DictationSettings(
            language: "zh-CN",
            whisper: false,
            translateEnabled: false,
            translateTarget: "en-US",
            selectedText: nil,
            keyboardType: 0,
            session: "expired-settings",
            timestamp: now - 61
        )
        DarwinBridge.writeDictationSettings(settings)

        XCTAssertNil(DarwinBridge.peekPendingDictationSettings(now: now, maxAge: 60))
        XCTAssertNil(
            DarwinBridge.readAndConsumeDictationSettings(
                expectedSession: "expired-settings",
                now: now
            )
        )
    }

    func testRequeueDoesNotOverwriteNewerSession() {
        let now = Date().timeIntervalSince1970
        let old = DictationSettings(
            language: "zh-CN",
            whisper: false,
            translateEnabled: false,
            translateTarget: "en-US",
            selectedText: nil,
            keyboardType: 0,
            session: UUID().uuidString,
            timestamp: now
        )
        let newer = DictationSettings(
            language: "en-US",
            whisper: true,
            translateEnabled: true,
            translateTarget: "zh-CN",
            selectedText: "keep me",
            keyboardType: 7,
            session: UUID().uuidString,
            timestamp: now + 1
        )
        DarwinBridge.writeDictationSettings(newer)

        XCTAssertFalse(
            DarwinBridge.requeueDictationSettingsIfNotSuperseded(old, now: now + 1)
        )
        XCTAssertEqual(DarwinBridge.peekPendingDictationSettings(now: now + 1), newer)
    }
}
