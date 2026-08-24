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
}
