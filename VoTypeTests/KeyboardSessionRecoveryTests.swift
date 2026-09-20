import XCTest
@testable import VoiceInputApp

final class KeyboardSessionRecoveryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "KeyboardSessionRecoveryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
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
