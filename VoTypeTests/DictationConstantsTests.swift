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

    // MARK: - 实时原地反馈

    func testLiveStateCanBeReadRepeatedlyForExpectedSession() {
        let now = Date().timeIntervalSince1970
        let session = UUID().uuidString

        XCTAssertTrue(
            DarwinBridge.writeLiveState(
                phase: .listening,
                partialTranscript: "正在识别的文字",
                session: session,
                timestamp: now
            )
        )

        let first = DarwinBridge.readLiveState(expectedSession: session, now: now)
        let second = DarwinBridge.readLiveState(expectedSession: session, now: now)
        XCTAssertEqual(first?.session, session)
        XCTAssertEqual(first?.phase, .listening)
        XCTAssertEqual(first?.partialTranscript, "正在识别的文字")
        XCTAssertEqual(second, first)
    }

    func testLiveStatesAreIndependentAndSessionChecked() {
        let now = Date().timeIntervalSince1970
        let sessionA = UUID().uuidString
        let sessionB = UUID().uuidString

        XCTAssertTrue(
            DarwinBridge.writeLiveState(
                phase: .starting,
                session: sessionA,
                timestamp: now
            )
        )
        XCTAssertTrue(
            DarwinBridge.writeLiveState(
                phase: .listening,
                partialTranscript: "B",
                session: sessionB,
                timestamp: now + 1
            )
        )

        XCTAssertEqual(
            DarwinBridge.readLiveState(expectedSession: sessionA, now: now + 1)?.phase,
            .starting
        )
        XCTAssertEqual(
            DarwinBridge.readLiveState(expectedSession: sessionB, now: now + 1)?.partialTranscript,
            "B"
        )
        XCTAssertNil(
            DarwinBridge.readLiveState(
                expectedSession: UUID().uuidString,
                now: now + 1
            )
        )
    }

    func testOlderLiveStateCannotOverwriteLatestSnapshot() {
        let now = Date().timeIntervalSince1970
        let session = UUID().uuidString

        XCTAssertTrue(
            DarwinBridge.writeLiveState(
                phase: .processing,
                partialTranscript: "latest",
                session: session,
                timestamp: now + 2
            )
        )
        XCTAssertFalse(
            DarwinBridge.writeLiveState(
                phase: .listening,
                partialTranscript: "late callback",
                session: session,
                timestamp: now + 1
            )
        )

        let state = DarwinBridge.readLiveState(expectedSession: session, now: now + 2)
        XCTAssertEqual(state?.phase, .processing)
        XCTAssertEqual(state?.partialTranscript, "latest")
    }

    func testExpiredLiveStateIsRemoved() {
        let now = Date().timeIntervalSince1970
        let session = UUID().uuidString
        DarwinBridge.writeLiveState(
            phase: .listening,
            partialTranscript: "expired",
            session: session,
            timestamp: now - DarwinBridge.liveStateMaxAge - 1
        )

        XCTAssertNil(DarwinBridge.readLiveState(expectedSession: session, now: now))
        XCTAssertNil(
            DarwinBridge.readLiveState(
                expectedSession: session,
                now: now,
                maxAge: 60
            )
        )
    }

    func testTerminalResultClearsProcessingLiveState() {
        let now = Date().timeIntervalSince1970
        let session = UUID().uuidString
        DarwinBridge.writeLiveState(
            phase: .processing,
            partialTranscript: "processing",
            session: session,
            timestamp: now
        )
        XCTAssertEqual(
            DarwinBridge.readLiveState(expectedSession: session, now: now)?.phase,
            .processing
        )

        XCTAssertTrue(
            DarwinBridge.writeTranscription(
                "done",
                session: session,
                timestamp: now + 1
            )
        )
        XCTAssertNil(DarwinBridge.readLiveState(expectedSession: session, now: now + 1))
    }

    func testLiveStateRejectsInvalidSessionAndDoesNotLeakTextInNames() throws {
        XCTAssertFalse(
            DarwinBridge.writeLiveState(
                phase: .listening,
                partialTranscript: "private words",
                session: "not-a-uuid"
            )
        )

        let session = UUID().uuidString
        XCTAssertTrue(
            DarwinBridge.writeLiveState(
                phase: .listening,
                partialTranscript: "private words",
                session: session
            )
        )
        let notificationName = try XCTUnwrap(
            DarwinBridge.sessionNotificationName(
                base: DarwinNotificationName.liveStateChanged,
                session: session
            )
        )
        XCTAssertFalse(notificationName.contains(session))
        XCTAssertFalse(notificationName.contains("private words"))

        let fileNames = try FileManager.default.contentsOfDirectory(
            atPath: ipcDirectory.path
        )
        XCTAssertFalse(fileNames.joined().contains(session))
        XCTAssertFalse(fileNames.joined().contains("private words"))
    }

    func testClearLiveStateIsIdempotent() {
        let session = UUID().uuidString
        DarwinBridge.writeLiveState(phase: .starting, session: session)

        XCTAssertTrue(DarwinBridge.clearLiveState(session: session))
        XCTAssertNil(DarwinBridge.readLiveState(expectedSession: session))
        XCTAssertTrue(DarwinBridge.clearLiveState(session: session))
    }

    func testCancelledSessionRejectsLateLiveAndTerminalWrites() {
        let session = UUID().uuidString
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
        XCTAssertTrue(DarwinBridge.writeLiveState(phase: .listening, session: session))

        XCTAssertTrue(DarwinBridge.cancelSession(session))
        XCTAssertTrue(DarwinBridge.isSessionCancelled(session: session))
        XCTAssertNil(DarwinBridge.peekPendingDictationSettings())
        XCTAssertNil(DarwinBridge.readLiveState(expectedSession: session))
        XCTAssertFalse(
            DarwinBridge.writeLiveState(
                phase: .processing,
                partialTranscript: "late partial",
                session: session
            )
        )
        XCTAssertFalse(DarwinBridge.writeTranscription("late", session: session))
        XCTAssertFalse(DarwinBridge.writeError("late error", session: session))
        XCTAssertNil(DarwinBridge.readAndConsumeResult(expectedSession: session))
    }

    func testCancellationRemovesTerminalThatAlreadyExists() {
        let session = UUID().uuidString
        XCTAssertTrue(DarwinBridge.writeTranscription("ready", session: session))
        XCTAssertEqual(DarwinBridge.peekResult()?.session, session)

        XCTAssertTrue(DarwinBridge.cancelSession(session))

        XCTAssertNil(DarwinBridge.peekResult())
        XCTAssertNil(DarwinBridge.readAndConsumeResult(expectedSession: session))
    }

    func testConcurrentCancellationCannotLeaveResultOrLiveState() {
        let sessions = (0..<24).map { _ in UUID().uuidString }
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "DictationConstantsTests.cancellationRace",
            attributes: .concurrent
        )

        for session in sessions {
            group.enter()
            queue.async {
                _ = DarwinBridge.writeLiveState(
                    phase: .listening,
                    partialTranscript: "late",
                    session: session
                )
                _ = DarwinBridge.writeTranscription("late", session: session)
                group.leave()
            }
            group.enter()
            queue.async {
                _ = DarwinBridge.cancelSession(session)
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        for session in sessions {
            XCTAssertTrue(DarwinBridge.isSessionCancelled(session: session))
            XCTAssertNil(DarwinBridge.readLiveState(expectedSession: session))
            XCTAssertNil(DarwinBridge.readAndConsumeResult(expectedSession: session))
        }
    }

    func testFirstTerminalResultWins() {
        let session = UUID().uuidString
        XCTAssertTrue(DarwinBridge.writeTranscription("first", session: session))
        XCTAssertFalse(DarwinBridge.writeError("late error", session: session))

        let result = DarwinBridge.readAndConsumeResult(expectedSession: session)
        XCTAssertEqual(result?.status, .completed)
        XCTAssertEqual(result?.transcription, "first")
    }

    func testConsumedTerminalReceiptRejectsLateSecondTerminal() {
        let session = UUID().uuidString
        XCTAssertTrue(DarwinBridge.writeTranscription("first", session: session))

        let consumed = DarwinBridge.readAndConsumeResult(expectedSession: session)
        XCTAssertEqual(consumed?.transcription, "first")
        XCTAssertNil(DarwinBridge.peekResult(expectedSession: session))

        XCTAssertFalse(DarwinBridge.writeError("late error", session: session))
        XCTAssertFalse(DarwinBridge.writeTranscription("duplicate", session: session))
        XCTAssertFalse(
            DarwinBridge.writeLiveState(
                phase: .listening,
                partialTranscript: "late partial",
                session: session
            )
        )
        XCTAssertNil(DarwinBridge.peekResult(expectedSession: session))
        XCTAssertNil(DarwinBridge.readAndConsumeResult(expectedSession: session))
    }

    func testLivePhaseCannotRegressFromProcessingToListening() {
        let now = Date().timeIntervalSince1970
        let session = UUID().uuidString
        XCTAssertTrue(
            DarwinBridge.writeLiveState(
                phase: .processing,
                partialTranscript: "finalizing",
                session: session,
                timestamp: now
            )
        )
        XCTAssertFalse(
            DarwinBridge.writeLiveState(
                phase: .listening,
                partialTranscript: "late partial",
                session: session,
                timestamp: now + 1
            )
        )
        XCTAssertEqual(
            DarwinBridge.readLiveState(expectedSession: session, now: now + 1)?.phase,
            .processing
        )
    }

    func testCancellationIsSessionScoped() {
        let cancelled = UUID().uuidString
        let active = UUID().uuidString
        XCTAssertTrue(DarwinBridge.cancelSession(cancelled))

        XCTAssertTrue(DarwinBridge.writeTranscription("active", session: active))
        XCTAssertEqual(
            DarwinBridge.readAndConsumeResult(expectedSession: active)?.transcription,
            "active"
        )
        XCTAssertFalse(DarwinBridge.isSessionCancelled(session: active))
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

    func testConsumingLatestSettingsDiscardsOlderPendingRequests() {
        let now = Date().timeIntervalSince1970
        let older = DictationSettings(
            language: "zh-CN",
            whisper: false,
            translateEnabled: false,
            translateTarget: "en-US",
            selectedText: nil,
            keyboardType: 0,
            session: UUID().uuidString,
            timestamp: now
        )
        let latest = DictationSettings(
            language: "en-US",
            whisper: false,
            translateEnabled: false,
            translateTarget: "zh-CN",
            selectedText: nil,
            keyboardType: 0,
            session: UUID().uuidString,
            timestamp: now + 1
        )
        XCTAssertTrue(DarwinBridge.writeDictationSettings(older))
        XCTAssertTrue(DarwinBridge.writeDictationSettings(latest))

        XCTAssertEqual(
            DarwinBridge.readAndConsumeDictationSettings(
                expectedSession: latest.session,
                now: now + 1
            ),
            latest
        )
        XCTAssertNil(DarwinBridge.peekPendingDictationSettings(now: now + 1))
    }
}
