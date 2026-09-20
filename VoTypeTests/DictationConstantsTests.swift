import XCTest
import CryptoKit
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

    // MARK: - Manual recovery and held-result contracts

    private func handoffSettings(_ token: SessionToken, timestamp: TimeInterval = Date().timeIntervalSince1970) -> DictationSettings {
        DictationSettings(language: "ja-JP", whisper: true, translateEnabled: true,
            translateTarget: "en-US", selectedText: "original selection", keyboardType: 7,
            session: token.rawValue, expectedContextFingerprint: "fingerprint", timestamp: timestamp)
    }

    private var heldPlan: EditPlan {
        EditPlan(intent: .dictate, operation: .insertAtCursor, text: "result",
                 expectedContextFingerprint: "fingerprint", requiresConfirmation: false)
    }

    private func businessBytes() throws -> [String: Data] {
        let urls = try FileManager.default.contentsOfDirectory(at: ipcDirectory, includingPropertiesForKeys: nil)
        return try Dictionary(uniqueKeysWithValues: urls.filter { $0.pathExtension == "json" }.map {
            ($0.lastPathComponent, try Data(contentsOf: $0))
        })
    }

    private func businessURL(_ kind: String, token: SessionToken) -> URL {
        let digest = SHA256.hash(data: Data(token.rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
        return ipcDirectory.appendingPathComponent("dictation-\(kind)-\(digest).json")
    }

    func testTypedPreviewConsumeRaceReturnsPayloadOnlyOnceAndPreservesReceipt() throws {
        let token = SessionToken()
        let other = SessionToken()
        XCTAssertEqual(DarwinBridge.commit(.completed(heldPlan), token: token), .written)
        XCTAssertEqual(DarwinBridge.commit(.completed(heldPlan), token: other), .written)
        let preview = try XCTUnwrap(DarwinBridge.peekResult(expectedSession: token.rawValue))
        let receipt = try Data(contentsOf: businessURL("terminal", token: token))
        let otherBytes = try Data(contentsOf: businessURL("result", token: other))
        let winner = try XCTUnwrap(DarwinBridge.readAndConsumeResult(expectedSession: token.rawValue))
        XCTAssertEqual(winner, preview)
        XCTAssertTrue(KeyboardHeldEditValidator.consumedResultMatchesPreview(previewed: preview, consumed: winner))
        // A second action holding the same preview loses the consume race.
        XCTAssertNil(DarwinBridge.readAndConsumeResult(expectedSession: token.rawValue))
        XCTAssertEqual(try Data(contentsOf: businessURL("terminal", token: token)), receipt)
        XCTAssertEqual(try Data(contentsOf: businessURL("result", token: other)), otherBytes)
        XCTAssertEqual(DarwinBridge.commit(.failed(.recognition), token: token), .alreadyTerminal)
    }

    func testSelectionRejectionLeavesPublishedPayloadAndReceiptBytesUntouched() throws {
        for operation in [EditOperation.insertAtCursor, .previewOnly] {
            let token = SessionToken()
            let plan = EditPlan(intent: .rewrite, operation: operation, text: "result",
                                expectedContextFingerprint: nil, requiresConfirmation: true)
            XCTAssertEqual(DarwinBridge.commit(.completed(plan), token: token), .written)
            let preview = try XCTUnwrap(DarwinBridge.peekResult(expectedSession: token.rawValue))
            let bytes = try businessBytes()
            // Pure validator + real IPC retention contract, not a keyboard controller test.
            XCTAssertEqual(KeyboardHeldEditValidator.decide(
                plan: try XCTUnwrap(preview.editPlan), previewedToken: token, heldToken: token,
                snapshotToken: nil, snapshotFingerprint: nil, hasContextEvidence: false,
                contextMatches: false, currentSelectedText: "original selection"), .reject)
            XCTAssertEqual(try businessBytes(), bytes)
            XCTAssertEqual(DarwinBridge.peekResult(expectedSession: token.rawValue), preview)
            // Copy/Discard can still consume that exact payload after rejection.
            XCTAssertEqual(DarwinBridge.readAndConsumeResult(expectedSession: token.rawValue), preview)
        }
    }

    func testHotTimeoutHandoffCopiesImmutableSettingsAfterBackgroundClaimAndBlocksOldWrites() throws {
        let old = SessionToken()
        let manual = SessionToken()
        let now = Date().timeIntervalSince1970
        let original = handoffSettings(old, timestamp: now)
        XCTAssertTrue(DarwinBridge.writeDictationSettings(original))
        XCTAssertEqual(DarwinBridge.readAndConsumeDictationSettings(expectedSession: old.rawValue), original)
        XCTAssertTrue(DarwinBridge.writeLiveState(phase: .processing, session: old.rawValue))
        guard case .moved(let replacement) = DarwinBridge.handoffDictationSettingsToManual(
            from: old, to: manual, original: original, timestamp: now - 1) else {
            return XCTFail("Expected a fresh pending manual request")
        }
        XCTAssertEqual(replacement, DictationSettings(language: "ja-JP", whisper: true,
            translateEnabled: true, translateTarget: "en-US", selectedText: "original selection",
            keyboardType: 7, session: manual.rawValue, expectedContextFingerprint: "fingerprint",
            timestamp: now.nextUp))
        XCTAssertEqual(DarwinBridge.peekPendingDictationSettings(), replacement)
        XCTAssertNil(DarwinBridge.peekDictationSettings(expectedSession: old.rawValue))
        XCTAssertNil(DarwinBridge.readLiveState(expectedSession: old.rawValue))
        XCTAssertTrue(DarwinBridge.isSessionCancelled(session: old.rawValue))
        XCTAssertFalse(FileManager.default.fileExists(atPath: businessURL("terminal", token: old).path))
        XCTAssertEqual(DarwinBridge.commit(.completed(heldPlan), token: old), .cancelled)
        XCTAssertEqual(DarwinBridge.commit(.failed(.recognition), token: old), .cancelled)
        XCTAssertFalse(DarwinBridge.writeLiveState(phase: .listening, session: old.rawValue))
        XCTAssertFalse(DarwinBridge.writeDictationSettings(original))
        XCTAssertFalse(DarwinBridge.requeueDictationSettingsIfNotSuperseded(original))
        XCTAssertEqual(DarwinBridge.peekDictationSettings(expectedSession: manual.rawValue), replacement)
    }

    func testHandoffTerminalPayloadAndConsumedReceiptRemainUnchanged() throws {
        for mode in ["published", "consumed", "result-only"] {
            let old = SessionToken()
            let original = handoffSettings(old)
            XCTAssertTrue(DarwinBridge.writeDictationSettings(original))
            XCTAssertEqual(DarwinBridge.commit(.completed(heldPlan), token: old), .written)
            if mode == "consumed" {
                XCTAssertNotNil(DarwinBridge.readAndConsumeResult(expectedSession: old.rawValue))
            } else if mode == "result-only" {
                try FileManager.default.removeItem(at: businessURL("terminal", token: old))
            }
            let bytes = try businessBytes()
            XCTAssertEqual(DarwinBridge.handoffDictationSettingsToManual(
                from: old, to: SessionToken(), original: original), .alreadyTerminal, mode)
            XCTAssertEqual(try businessBytes(), bytes, mode)
        }
    }

    func testHandoffMalformedAndExpiredSourceTerminalFilesAreReadOnlyBarriers() throws {
        for kind in ["terminal", "result"] {
            for malformed in [false, true] {
                let old = SessionToken()
                let original = handoffSettings(old)
                XCTAssertTrue(DarwinBridge.writeDictationSettings(original))
                let expired = kind == "terminal"
                    ? "{\"session\":\"\(old.rawValue)\",\"timestamp\":1}"
                    : "{\"session\":\"\(old.rawValue)\",\"status\":\"completed\",\"text\":\"expired\",\"timestamp\":1}"
                try Data((malformed ? "broken-json" : expired).utf8).write(to: businessURL(kind, token: old))
                let bytes = try businessBytes()
                XCTAssertEqual(DarwinBridge.handoffDictationSettingsToManual(
                    from: old, to: SessionToken(), original: original), .alreadyTerminal)
                XCTAssertEqual(try businessBytes(), bytes)
                // Isolate deliberately stale/corrupt fixtures from later public-API GC.
                DarwinBridge.clearIPCFilesForTesting()
            }
        }
    }

    func testHandoffCancelledSourceAndOccupiedReplacementNeverChangeBusinessFiles() throws {
        for kind in ["settings", "result", "terminal", "cancel"] {
            let old = SessionToken()
            let replacement = SessionToken()
            let original = handoffSettings(old)
            XCTAssertTrue(DarwinBridge.writeDictationSettings(original))
            switch kind {
            case "settings": XCTAssertTrue(DarwinBridge.writeDictationSettings(handoffSettings(replacement)))
            case "cancel": XCTAssertTrue(DarwinBridge.cancelSession(replacement.rawValue))
            default:
                XCTAssertEqual(DarwinBridge.commit(.completed(heldPlan), token: replacement), .written)
                if kind == "terminal" {
                    XCTAssertNotNil(DarwinBridge.readAndConsumeResult(expectedSession: replacement.rawValue))
                } else {
                    try FileManager.default.removeItem(at: businessURL("terminal", token: replacement))
                }
            }
            let bytes = try businessBytes()
            XCTAssertEqual(DarwinBridge.handoffDictationSettingsToManual(
                from: old, to: replacement, original: original), .failed, kind)
            XCTAssertEqual(try businessBytes(), bytes, kind)
        }
        let old = SessionToken()
        let original = handoffSettings(old)
        XCTAssertTrue(DarwinBridge.writeDictationSettings(original))
        XCTAssertTrue(DarwinBridge.cancelSession(old.rawValue))
        let bytes = try businessBytes()
        XCTAssertEqual(DarwinBridge.handoffDictationSettingsToManual(
            from: old, to: SessionToken(), original: original), .failed)
        XCTAssertEqual(try businessBytes(), bytes)
    }

    func testHandoffCorruptAndExpiredOccupancyCannotBeCleanedOrReused() throws {
        for kind in ["settings", "result", "terminal", "cancel"] {
            for malformed in [false, true] {
                let old = SessionToken()
                let replacement = SessionToken()
                let original = handoffSettings(old)
                XCTAssertTrue(DarwinBridge.writeDictationSettings(original))
                let expired: Data
                switch kind {
                case "settings": expired = try JSONEncoder().encode(handoffSettings(replacement, timestamp: 1))
                case "result": expired = try JSONEncoder().encode(DictationIPCResult(status: .completed,
                    text: "expired", token: replacement, editPlan: heldPlan, timestamp: 1))
                default: expired = Data("{\"session\":\"\(replacement.rawValue)\",\"timestamp\":1}".utf8)
                }
                try (malformed ? Data("broken-json".utf8) : expired).write(to: businessURL(kind, token: replacement))
                let bytes = try businessBytes()
                XCTAssertEqual(DarwinBridge.handoffDictationSettingsToManual(
                    from: old, to: replacement, original: original), .failed)
                XCTAssertEqual(try businessBytes(), bytes)
                DarwinBridge.clearIPCFilesForTesting()
            }
        }
        for malformed in [false, true] {
            let old = SessionToken()
            let original = handoffSettings(old)
            XCTAssertTrue(DarwinBridge.writeDictationSettings(original))
            let expired = "{\"session\":\"\(old.rawValue)\",\"timestamp\":1}"
            try Data((malformed ? "broken-json" : expired).utf8).write(to: businessURL("cancel", token: old))
            let bytes = try businessBytes()
            XCTAssertEqual(DarwinBridge.handoffDictationSettingsToManual(
                from: old, to: SessionToken(), original: original), .failed)
            XCTAssertEqual(try businessBytes(), bytes)
            DarwinBridge.clearIPCFilesForTesting()
        }
    }

    func testHandoffInvalidIdentityOrTimestampIsReadOnly() throws {
        let old = SessionToken()
        let replacement = SessionToken()
        let original = handoffSettings(old)
        XCTAssertTrue(DarwinBridge.writeDictationSettings(original))
        let bytes = try businessBytes()
        XCTAssertEqual(DarwinBridge.handoffDictationSettingsToManual(from: old, to: old, original: original), .failed)
        XCTAssertEqual(DarwinBridge.handoffDictationSettingsToManual(
            from: old, to: replacement, original: handoffSettings(SessionToken())), .failed)
        for timestamp in [0.0, -1.0, Double.nan, Double.infinity] {
            XCTAssertEqual(DarwinBridge.handoffDictationSettingsToManual(
                from: old, to: replacement, original: original, timestamp: timestamp), .failed)
            XCTAssertEqual(try businessBytes(), bytes)
        }
    }

    func testHandoffMissingContainerFailsWithoutChangingExistingFiles() throws {
        let old = SessionToken()
        let original = handoffSettings(old)
        XCTAssertTrue(DarwinBridge.writeDictationSettings(original))
        let bytes = try businessBytes()
        DarwinBridge.setContainerDirectoryForTesting(nil)
        defer { DarwinBridge.setContainerDirectoryForTesting(ipcDirectory) }
        XCTAssertEqual(DarwinBridge.handoffDictationSettingsToManual(
            from: old, to: SessionToken(), original: original), .failed)
        XCTAssertEqual(try businessBytes(), bytes)
    }

    func testExplicitRetryUsesFreshManualUUIDAndCannotReplayOldTerminal() throws {
        let old = SessionToken()
        let retry = SessionToken()
        XCTAssertEqual(DarwinBridge.commit(.failed(.recognition), token: old), .written)
        XCTAssertNotNil(DarwinBridge.readAndConsumeResult(expectedSession: old.rawValue))
        let oldReceipt = try Data(contentsOf: businessURL("terminal", token: old))
        let suite = "ManualRetry-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = try XCTUnwrap(KeyboardSessionRecoveryStore.save(
            session: retry.rawValue, launchMode: .manualOpen, contextBefore: "new field",
            contextAfter: nil, selectedText: nil, defaults: defaults))
        XCTAssertNotEqual(retry, old)
        let settings = DictationSettings(language: "zh-CN", whisper: false,
            translateEnabled: false, translateTarget: "en-US", selectedText: nil,
            keyboardType: 0, session: retry.rawValue, expectedContextFingerprint: snapshot.contextFingerprint)
        XCTAssertTrue(DarwinBridge.writeDictationSettings(settings))
        XCTAssertEqual(DarwinBridge.peekPendingDictationSettings(), settings)
        XCTAssertEqual(snapshot.session, retry.rawValue)
        XCTAssertNil(DarwinBridge.peekResult(expectedSession: retry.rawValue))
        XCTAssertEqual(DarwinBridge.commit(.completed(heldPlan), token: old), .alreadyTerminal)
        XCTAssertNil(DarwinBridge.peekResult(expectedSession: old.rawValue))
        XCTAssertEqual(try Data(contentsOf: businessURL("terminal", token: old)), oldReceipt)
        XCTAssertEqual(DarwinBridge.commit(.completed(heldPlan), token: retry), .written)
        XCTAssertEqual(KeyboardResultDispositionPolicy.decide(
            launchMode: snapshot.launchMode, belongsToCurrentExtensionInstance: true,
            currentSelectedText: nil, hasContextEvidence: snapshot.hasContextEvidence,
            contextMatches: true, operation: .insertAtCursor, requiresConfirmation: false), .hold)
        XCTAssertNotNil(DarwinBridge.peekResult(expectedSession: retry.rawValue))
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
        let session1 = UUID().uuidString
        let session2 = UUID().uuidString

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
        let session = UUID().uuidString
        DarwinBridge.writeTranscription("过期", session: session, timestamp: now - 301)

        XCTAssertNil(DarwinBridge.peekResult(now: now, maxAge: 300))
        XCTAssertNil(DarwinBridge.readAndConsumeResult(expectedSession: session, now: now))
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

    func testFreshStandbyReadinessAllowsInPlaceStart() {
        let now = Date().timeIntervalSince1970
        XCTAssertTrue(DarwinBridge.writeReadiness(.standby, timestamp: now))

        XCTAssertEqual(
            DarwinBridge.readReadiness(now: now)?.mode,
            .standby
        )
        XCTAssertTrue(DarwinBridge.canStartInPlace(now: now + 1))
    }

    func testReadinessExpiresInsteadOfLeavingFalseReadyState() {
        let now = Date().timeIntervalSince1970
        XCTAssertTrue(DarwinBridge.writeReadiness(.standby, timestamp: now))

        XCTAssertNil(
            DarwinBridge.readReadiness(
                now: now + DarwinBridge.readinessMaxAge + 0.1
            )
        )
        XCTAssertFalse(
            DarwinBridge.canStartInPlace(
                now: now + DarwinBridge.readinessMaxAge + 0.1
            )
        )
    }

    func testRecordingReadinessDoesNotAcceptAnotherStart() {
        let now = Date().timeIntervalSince1970
        XCTAssertTrue(DarwinBridge.writeReadiness(.recording, timestamp: now))

        XCTAssertEqual(DarwinBridge.readReadiness(now: now)?.mode, .recording)
        XCTAssertFalse(DarwinBridge.canStartInPlace(now: now))
    }

    func testClearReadinessIsIdempotent() {
        XCTAssertTrue(DarwinBridge.writeReadiness(.standby))
        XCTAssertTrue(DarwinBridge.clearReadiness())
        XCTAssertNil(DarwinBridge.readReadiness())
        XCTAssertTrue(DarwinBridge.clearReadiness())
    }

    func testDarwinBridgeDictationSettings() {
        let session = UUID().uuidString
        let settings = DictationSettings(
            language: "zh-CN",
            whisper: true,
            translateEnabled: false,
            translateTarget: "en",
            selectedText: "选中文本",
            keyboardType: 1,
            session: session
        )

        DarwinBridge.writeDictationSettings(settings)

        let pending = DarwinBridge.peekPendingDictationSettings()
        XCTAssertEqual(pending?.session, session)

        let read = DarwinBridge.readAndConsumeDictationSettings(
            expectedSession: session
        )
        XCTAssertNotNil(read)
        XCTAssertEqual(read?.language, "zh-CN")
        XCTAssertEqual(read?.whisper, true)
        XCTAssertEqual(read?.translateEnabled, false)
        XCTAssertEqual(read?.translateTarget, "en")
        XCTAssertEqual(read?.selectedText, "选中文本")
        XCTAssertEqual(read?.keyboardType, 1)
        XCTAssertEqual(read?.session, session)
        XCTAssertNil(DarwinBridge.peekPendingDictationSettings())
    }

    func testTwentySequentialSessionRoundTripsLeaveNoStaleState() {
        for index in 0..<20 {
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
            XCTAssertEqual(
                DarwinBridge.readAndConsumeDictationSettings(
                    expectedSession: session
                ),
                settings
            )
            XCTAssertTrue(
                DarwinBridge.writeLiveState(
                    phase: .listening,
                    partialTranscript: "第\(index)轮",
                    session: session
                )
            )
            XCTAssertTrue(
                DarwinBridge.writeLiveState(
                    phase: .processing,
                    partialTranscript: "第\(index)轮",
                    session: session
                )
            )
            XCTAssertTrue(
                DarwinBridge.writeTranscription("结果\(index)", session: session)
            )
            XCTAssertEqual(
                DarwinBridge.readAndConsumeResult(
                    expectedSession: session
                )?.transcription,
                "结果\(index)"
            )
            XCTAssertNil(DarwinBridge.readLiveState(expectedSession: session))
        }
        XCTAssertNil(DarwinBridge.peekPendingDictationSettings())
        XCTAssertNil(DarwinBridge.peekResult())
    }

    func testExpiredSettingsAreRemoved() {
        let now = Date().timeIntervalSince1970
        let session = UUID().uuidString
        let settings = DictationSettings(
            language: "zh-CN",
            whisper: false,
            translateEnabled: false,
            translateTarget: "en-US",
            selectedText: nil,
            keyboardType: 0,
            session: session,
            timestamp: now - 61
        )
        DarwinBridge.writeDictationSettings(settings)

        XCTAssertNil(DarwinBridge.peekPendingDictationSettings(now: now, maxAge: 60))
        XCTAssertNil(
            DarwinBridge.readAndConsumeDictationSettings(
                expectedSession: session,
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

    func testPeekDictationSettingsReturnsExactSessionWithoutConsumingIt() {
        let session = UUID().uuidString
        let settings = DictationSettings(
            language: "zh-CN",
            whisper: false,
            translateEnabled: false,
            translateTarget: "en-US",
            selectedText: "选区",
            keyboardType: 0,
            session: session
        )
        XCTAssertTrue(DarwinBridge.writeDictationSettings(settings))

        XCTAssertEqual(
            DarwinBridge.peekDictationSettings(expectedSession: session),
            settings
        )
        XCTAssertEqual(
            DarwinBridge.readAndConsumeDictationSettings(expectedSession: session),
            settings
        )
    }

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

    func testDictationSettingsRoundTripsExpectedContextFingerprint() throws {
        let settings = DictationSettings(
            language: "zh-CN",
            whisper: false,
            translateEnabled: false,
            translateTarget: "en-US",
            selectedText: nil,
            keyboardType: 0,
            session: UUID().uuidString,
            expectedContextFingerprint: "context-digest"
        )

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(DictationSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.expectedContextFingerprint, "context-digest")
    }

    func testLegacyDictationSettingsDecodeWithoutContextFingerprint() throws {
        let session = UUID().uuidString
        let json = """
        {"language":"zh-CN","whisper":true,"translateEnabled":false,"translateTarget":"en-US","selectedText":"旧选区","keyboardType":3,"session":"\(session)","timestamp":100}
        """

        let decoded = try JSONDecoder().decode(
            DictationSettings.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.session, session)
        XCTAssertEqual(decoded.language, "zh-CN")
        XCTAssertTrue(decoded.whisper)
        XCTAssertFalse(decoded.translateEnabled)
        XCTAssertEqual(decoded.translateTarget, "en-US")
        XCTAssertEqual(decoded.selectedText, "旧选区")
        XCTAssertEqual(decoded.keyboardType, 3)
        XCTAssertEqual(decoded.expectedContextFingerprint, nil)
    }
}
