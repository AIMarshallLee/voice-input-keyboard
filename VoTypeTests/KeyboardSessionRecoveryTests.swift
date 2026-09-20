import XCTest
import CryptoKit
@testable import VoiceInputApp

final class KeyboardSessionRecoveryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var ipcDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "KeyboardSessionRecoveryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        ipcDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("RecoveryIPC-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ipcDirectory, withIntermediateDirectories: true)
        DarwinBridge.setContainerDirectoryForTesting(ipcDirectory)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        DarwinBridge.clearIPCFilesForTesting()
        DarwinBridge.resetContainerDirectoryAfterTesting()
        try FileManager.default.removeItem(at: ipcDirectory)
        try super.tearDownWithError()
    }

    func testRoundTripStoresNoPlainEditorText() throws {
        let session = UUID().uuidString
        let before = "private text before cursor"
        let after = "private text after cursor"
        let selected = "private selection"

        let saved = KeyboardSessionRecoveryStore.save(
            session: session,
            launchMode: .manualOpen,
            contextBefore: before,
            contextAfter: after,
            selectedText: selected,
            timestamp: 100,
            defaults: defaults
        )
        let loaded = KeyboardSessionRecoveryStore.load(
            now: 101,
            defaults: defaults
        )

        XCTAssertEqual(saved, loaded)
        XCTAssertEqual(saved?.hasContextEvidence, true)
        let storedData = try XCTUnwrap(defaults.data(forKey: "keyboardSessionRecovery.v1"))
        let storedString = String(decoding: storedData, as: UTF8.self)
        XCTAssertFalse(storedString.contains(before))
        XCTAssertFalse(storedString.contains(after))
        XCTAssertFalse(storedString.contains(selected))
    }

    func testContextMustStillMatch() throws {
        let snapshot = try XCTUnwrap(
            KeyboardSessionRecoveryStore.save(
                session: UUID().uuidString,
                launchMode: .manualOpen,
                contextBefore: "hello ",
                contextAfter: "world",
                selectedText: nil,
                defaults: defaults
            )
        )

        XCTAssertTrue(
            KeyboardSessionRecoveryStore.matches(
                snapshot,
                contextBefore: "hello ",
                contextAfter: "world",
                selectedText: nil
            )
        )
        XCTAssertFalse(
            KeyboardSessionRecoveryStore.matches(
                snapshot,
                contextBefore: "changed ",
                contextAfter: "world",
                selectedText: nil
            )
        )
        XCTAssertFalse(
            KeyboardSessionRecoveryStore.matches(
                snapshot,
                contextBefore: "hello ",
                contextAfter: "world",
                selectedText: "selection"
            )
        )
    }

    func testEmptyEditorDoesNotProvideEnoughEvidenceForAutomaticInsertion() throws {
        let snapshot = try XCTUnwrap(
            KeyboardSessionRecoveryStore.save(
                session: UUID().uuidString,
                launchMode: .manualOpen,
                contextBefore: "",
                contextAfter: "",
                selectedText: nil,
                defaults: defaults
            )
        )

        XCTAssertFalse(snapshot.hasContextEvidence)
        XCTAssertTrue(
            KeyboardSessionRecoveryStore.matches(
                snapshot,
                contextBefore: "",
                contextAfter: "",
                selectedText: nil
            )
        )
    }

    func testExpiredSnapshotIsRemoved() {
        KeyboardSessionRecoveryStore.save(
            session: UUID().uuidString,
            launchMode: .manualOpen,
            contextBefore: nil,
            contextAfter: nil,
            selectedText: nil,
            timestamp: 10,
            defaults: defaults
        )

        XCTAssertNil(
            KeyboardSessionRecoveryStore.load(
                now: 10 + KeyboardSessionRecoveryStore.maxAge + 1,
                defaults: defaults
            )
        )
        XCTAssertNil(defaults.data(forKey: "keyboardSessionRecovery.v1"))
    }

    func testClearDoesNotRemoveNewerSession() throws {
        let currentSession = UUID().uuidString
        KeyboardSessionRecoveryStore.save(
            session: currentSession,
            launchMode: .manualOpen,
            contextBefore: nil,
            contextAfter: nil,
            selectedText: nil,
            defaults: defaults
        )

        KeyboardSessionRecoveryStore.clear(
            expectedSession: UUID().uuidString,
            defaults: defaults
        )
        XCTAssertEqual(
            KeyboardSessionRecoveryStore.load(defaults: defaults)?.session,
            currentSession
        )

        KeyboardSessionRecoveryStore.clear(
            expectedSession: currentSession,
            defaults: defaults
        )
        XCTAssertNil(KeyboardSessionRecoveryStore.load(defaults: defaults))
    }

    func testLegacySnapshotDefaultsToManualOpenAndDerivesFingerprint() throws {
        let session = UUID().uuidString
        let json = """
        {"session":"\(session)","contextBeforeDigest":"a","contextAfterDigest":"b","selectedTextDigest":"c","hasContextEvidence":true,"timestamp":100}
        """
        defaults.set(Data(json.utf8), forKey: "keyboardSessionRecovery.v1")
        let snapshot = try XCTUnwrap(KeyboardSessionRecoveryStore.load(now: 101, defaults: defaults))
        XCTAssertEqual(snapshot.launchMode, .manualOpen)
        // Independently calculated SHA256 of the UTF-8 literal a|b|c.
        XCTAssertEqual(snapshot.contextFingerprint, "a52dd81bfd5e4e66d96b9f598382f6cbf8c5c3897654e6ae9055e03620fcf38e")
    }

    func testInPlaceSnapshotRoundTripsFingerprintWithoutPlainText() throws {
        let snapshot = try XCTUnwrap(KeyboardSessionRecoveryStore.save(
            session: UUID().uuidString, launchMode: .inPlace,
            contextBefore: "private before", contextAfter: "private after",
            selectedText: "private selection", timestamp: 100, defaults: defaults))
        XCTAssertEqual(KeyboardSessionRecoveryStore.load(now: 101, defaults: defaults), snapshot)
        XCTAssertEqual(snapshot.launchMode, .inPlace)
        XCTAssertFalse(snapshot.contextFingerprint.isEmpty)
        let data = try XCTUnwrap(defaults.data(forKey: "keyboardSessionRecovery.v1"))
        let stored = String(decoding: data, as: UTF8.self)
        for value in ["private before", "private after", "private selection"] {
            XCTAssertFalse(stored.contains(value))
        }
    }

    func testMarkManualOpenChangesOnlyMatchingSessionAndPreservesEvidence() throws {
        let session = UUID().uuidString
        let original = try XCTUnwrap(KeyboardSessionRecoveryStore.save(
            session: session, launchMode: .inPlace, contextBefore: "before",
            contextAfter: "after", selectedText: "selection", defaults: defaults))
        let bytes = defaults.data(forKey: "keyboardSessionRecovery.v1")
        XCTAssertFalse(KeyboardSessionRecoveryStore.markManualOpen(session: UUID().uuidString, defaults: defaults))
        XCTAssertEqual(defaults.data(forKey: "keyboardSessionRecovery.v1"), bytes)
        XCTAssertTrue(KeyboardSessionRecoveryStore.markManualOpen(session: session, defaults: defaults))
        let changed = try XCTUnwrap(KeyboardSessionRecoveryStore.load(defaults: defaults))
        XCTAssertEqual(changed.launchMode, .manualOpen)
        XCTAssertEqual(changed.session, original.session)
        XCTAssertEqual(changed.timestamp, original.timestamp)
        assertEvidence(changed, equals: original)
    }

    func testManualHandoffRebindsOnlyMatchingSnapshotWithoutLosingEvidence() throws {
        let old = SessionToken()
        let replacement = SessionToken()
        let now = Date().timeIntervalSince1970
        let original = try XCTUnwrap(KeyboardSessionRecoveryStore.save(
            session: old.rawValue, launchMode: .inPlace, contextBefore: "before",
            contextAfter: "after", selectedText: "selection", timestamp: now - 2, defaults: defaults))
        let bytes = defaults.data(forKey: "keyboardSessionRecovery.v1")
        XCTAssertFalse(KeyboardSessionRecoveryStore.rebindForManualHandoff(
            from: SessionToken(), to: replacement, timestamp: now, defaults: defaults))
        XCTAssertEqual(defaults.data(forKey: "keyboardSessionRecovery.v1"), bytes)
        XCTAssertTrue(KeyboardSessionRecoveryStore.rebindForManualHandoff(
            from: old, to: replacement, timestamp: now, defaults: defaults))
        let rebound = try XCTUnwrap(KeyboardSessionRecoveryStore.load(now: now, defaults: defaults))
        XCTAssertEqual(rebound.session, replacement.rawValue)
        XCTAssertEqual(rebound.launchMode, .manualOpen)
        XCTAssertEqual(rebound.timestamp, now)
        assertEvidence(rebound, equals: original)
    }

    func testReceiptOnlyRecoveryChoosesRetryAndPreservesTerminalBarrier() throws {
        let token = SessionToken()
        let snapshot = try recoverySnapshot(token)
        XCTAssertTrue(DarwinBridge.writeDictationSettings(recoverySettings(token)))
        XCTAssertEqual(DarwinBridge.commit(.completed(recoveryPlan), token: token), .written)
        XCTAssertNotNil(DarwinBridge.readAndConsumeResult(expectedSession: token.rawValue))
        let receipt = try Data(contentsOf: recoveryFile("terminal", token: token))

        XCTAssertEqual(KeyboardSessionRecoveryStore.recoveryDecision(snapshot: snapshot, contextMatches: true), .retry(token))

        XCTAssertEqual(try Data(contentsOf: recoveryFile("terminal", token: token)), receipt)
        XCTAssertNil(DarwinBridge.peekResult(expectedSession: token.rawValue))
        XCTAssertEqual(DarwinBridge.commit(.completed(recoveryPlan), token: token), .alreadyTerminal)
    }

    func testFailedRebindMatchingContextCannotHideActualManualRequestOrResult() throws {
        for completed in [false, true] {
            let unrelated = SessionToken()
            let old = SessionToken()
            let manual = SessionToken()
            let snapshot = try recoverySnapshot(unrelated)
            let storedSnapshot = defaults.data(forKey: "keyboardSessionRecovery.v1")
            let settings = recoverySettings(old)
            XCTAssertTrue(DarwinBridge.writeDictationSettings(settings))
            guard case .moved = DarwinBridge.handoffDictationSettingsToManual(from: old, to: manual, original: settings) else {
                return XCTFail("Fixture must represent a completed handoff")
            }
            XCTAssertFalse(KeyboardSessionRecoveryStore.rebindForManualHandoff(from: old, to: manual, defaults: defaults))
            XCTAssertTrue(KeyboardSessionRecoveryStore.matches(snapshot,
                contextBefore: "same field", contextAfter: "after", selectedText: nil))
            if completed {
                XCTAssertNotNil(DarwinBridge.readAndConsumeDictationSettings(expectedSession: manual.rawValue))
                XCTAssertEqual(DarwinBridge.commit(.completed(recoveryPlan), token: manual), .written)
            }

            XCTAssertEqual(KeyboardSessionRecoveryStore.recoveryDecision(snapshot: snapshot, contextMatches: true), .restore(manual))

            XCTAssertEqual(defaults.data(forKey: "keyboardSessionRecovery.v1"), storedSnapshot,
                           "Discovery must not relabel unrelated editor evidence as the manual session's context")
            if completed { XCTAssertNotNil(DarwinBridge.peekResult(expectedSession: manual.rawValue)) }
            else { XCTAssertNotNil(DarwinBridge.peekDictationSettings(expectedSession: manual.rawValue)) }
            DarwinBridge.clearIPCFilesForTesting()
        }
    }

    func testCanceledSourceRecoveryRetriesWithoutPromotionAndDiscoversPromotedWork() throws {
        let source = SessionToken()
        let snapshot = try recoverySnapshot(source)
        XCTAssertTrue(DarwinBridge.writeDictationSettings(recoverySettings(source)))
        XCTAssertTrue(DarwinBridge.cancelSession(source.rawValue))
        let cancellation = try Data(contentsOf: recoveryFile("cancel", token: source))
        XCTAssertEqual(KeyboardSessionRecoveryStore.recoveryDecision(snapshot: snapshot, contextMatches: true), .retry(source))

        let replacement = SessionToken()
        XCTAssertTrue(DarwinBridge.writeDictationSettings(recoverySettings(replacement)))
        XCTAssertEqual(KeyboardSessionRecoveryStore.recoveryDecision(snapshot: snapshot, contextMatches: true), .restore(replacement))
        XCTAssertEqual(try Data(contentsOf: recoveryFile("cancel", token: source)), cancellation)
        XCTAssertEqual(KeyboardSessionRecoveryStore.load(defaults: defaults)?.session, source.rawValue)
    }

    func testSnapshotWithItsOwnRealEvidenceOutranksUnrelatedPendingWork() throws {
        for evidence in ["settings", "live", "result"] {
            let own = SessionToken()
            let other = SessionToken()
            let snapshot = try recoverySnapshot(own)
            switch evidence {
            case "settings": XCTAssertTrue(DarwinBridge.writeDictationSettings(recoverySettings(own)))
            case "live": XCTAssertTrue(DarwinBridge.writeLiveState(phase: .listening, session: own.rawValue))
            default: XCTAssertEqual(DarwinBridge.commit(.completed(recoveryPlan), token: own), .written)
            }
            XCTAssertTrue(DarwinBridge.writeDictationSettings(recoverySettings(other)))

            XCTAssertEqual(KeyboardSessionRecoveryStore.recoveryDecision(snapshot: snapshot, contextMatches: false), .restore(own), evidence)

            XCTAssertNotNil(DarwinBridge.peekDictationSettings(expectedSession: other.rawValue))
            DarwinBridge.clearIPCFilesForTesting()
        }
    }

    func testRecoveryWithoutSnapshotDiscoversWorkWithoutInventingContext() throws {
        XCTAssertEqual(KeyboardSessionRecoveryStore.recoveryDecision(snapshot: nil, contextMatches: false), .none)
        let token = SessionToken()
        XCTAssertTrue(DarwinBridge.writeDictationSettings(recoverySettings(token)))
        XCTAssertEqual(KeyboardSessionRecoveryStore.recoveryDecision(snapshot: nil, contextMatches: false), .restore(token))
        XCTAssertNotNil(DarwinBridge.readAndConsumeDictationSettings(expectedSession: token.rawValue))
        XCTAssertEqual(DarwinBridge.commit(.completed(recoveryPlan), token: token), .written)
        XCTAssertEqual(KeyboardSessionRecoveryStore.recoveryDecision(snapshot: nil, contextMatches: false), .restore(token))
        XCTAssertNotNil(DarwinBridge.peekResult(expectedSession: token.rawValue))
    }

    func testOwnLiveEvidenceIsNotPreemptedByUnrelatedCompletedResult() throws {
        let own = SessionToken()
        let other = SessionToken()
        let snapshot = try recoverySnapshot(own)
        XCTAssertTrue(DarwinBridge.writeLiveState(phase: .processing, session: own.rawValue))
        XCTAssertEqual(DarwinBridge.commit(.completed(recoveryPlan), token: other), .written)

        XCTAssertEqual(KeyboardSessionRecoveryStore.recoveryDecision(snapshot: snapshot, contextMatches: true), .restore(own))

        XCTAssertNotNil(DarwinBridge.peekResult(expectedSession: other.rawValue))
    }

    func testContextOnlyFallbackRequiresMatchingEvidenceAndNoDurableBarrier() throws {
        for kind in ["terminal", "cancel"] {
            let token = SessionToken()
            let snapshot = try recoverySnapshot(token)
            XCTAssertEqual(KeyboardSessionRecoveryStore.recoveryDecision(snapshot: snapshot, contextMatches: false), .none)
            XCTAssertEqual(KeyboardSessionRecoveryStore.recoveryDecision(snapshot: snapshot, contextMatches: true), .restore(token))
            let corruptBarrier = Data("corrupt-recovery-evidence".utf8)
            try corruptBarrier.write(to: recoveryFile(kind, token: token))
            XCTAssertEqual(KeyboardSessionRecoveryStore.recoveryDecision(snapshot: snapshot, contextMatches: true), .retry(token))
            XCTAssertEqual(try Data(contentsOf: recoveryFile(kind, token: token)), corruptBarrier)
            DarwinBridge.clearIPCFilesForTesting()
        }
    }

    func testEmptyContextDoesNotManufactureAnOngoingSession() throws {
        let snapshot = try XCTUnwrap(KeyboardSessionRecoveryStore.save(session: UUID().uuidString,
            launchMode: .inPlace, contextBefore: "", contextAfter: "", selectedText: nil, defaults: defaults))
        XCTAssertFalse(snapshot.hasContextEvidence)
        XCTAssertEqual(KeyboardSessionRecoveryStore.recoveryDecision(snapshot: snapshot, contextMatches: true), .none)
    }

    func testUnavailableStorageCannotRestoreContextOnlySnapshotWait() throws {
        let token = SessionToken()
        let snapshot = try recoverySnapshot(token)
        let storedSnapshot = defaults.data(forKey: "keyboardSessionRecovery.v1")
        let blockedContainer = ipcDirectory.appendingPathComponent("not-a-directory")
        let bytes = Data("unavailable-recovery-container".utf8)
        try bytes.write(to: blockedContainer)
        defer { DarwinBridge.setContainerDirectoryForTesting(ipcDirectory) }
        for unavailable in [nil, blockedContainer] as [URL?] {
            DarwinBridge.setContainerDirectoryForTesting(unavailable)
            XCTAssertEqual(KeyboardSessionRecoveryStore.recoveryDecision(snapshot: snapshot, contextMatches: true), .retry(token),
                           "Unknown IPC state cannot justify restoring a context-only wait")
        }
        XCTAssertEqual(defaults.data(forKey: "keyboardSessionRecovery.v1"), storedSnapshot)
        XCTAssertEqual(try Data(contentsOf: blockedContainer), bytes)
    }

    private func recoverySnapshot(_ token: SessionToken) throws -> KeyboardSessionRecoverySnapshot {
        try XCTUnwrap(KeyboardSessionRecoveryStore.save(session: token.rawValue, launchMode: .inPlace,
            contextBefore: "same field", contextAfter: "after", selectedText: nil, defaults: defaults))
    }

    private func recoverySettings(_ token: SessionToken) -> DictationSettings {
        DictationSettings(language: "zh-CN", whisper: false, translateEnabled: false,
            translateTarget: "en-US", selectedText: nil, keyboardType: 0, session: token.rawValue)
    }

    private var recoveryPlan: EditPlan {
        EditPlan(intent: .dictate, operation: .insertAtCursor, text: "manual result",
                 expectedContextFingerprint: nil, requiresConfirmation: false)
    }

    private func recoveryFile(_ kind: String, token: SessionToken) -> URL {
        let digest = SHA256.hash(data: Data(token.rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
        return ipcDirectory.appendingPathComponent("dictation-\(kind)-\(digest).json")
    }

    private func assertEvidence(_ actual: KeyboardSessionRecoverySnapshot,
                                equals expected: KeyboardSessionRecoverySnapshot,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.contextBeforeDigest, expected.contextBeforeDigest, file: file, line: line)
        XCTAssertEqual(actual.contextAfterDigest, expected.contextAfterDigest, file: file, line: line)
        XCTAssertEqual(actual.selectedTextDigest, expected.selectedTextDigest, file: file, line: line)
        XCTAssertEqual(actual.hasContextEvidence, expected.hasContextEvidence, file: file, line: line)
        XCTAssertEqual(actual.contextFingerprint, expected.contextFingerprint, file: file, line: line)
    }
}
