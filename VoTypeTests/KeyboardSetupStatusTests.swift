import XCTest
@testable import VoiceInputApp

final class KeyboardSetupStatusTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "KeyboardSetupStatusTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFreshInstallHasNoObservedKeyboardSetup() {
        XCTAssertEqual(
            KeyboardSetupStatusStore.read(defaults: defaults),
            KeyboardSetupStatus(keyboardObserved: false, fullAccessObserved: false)
        )
    }

    func testOpeningKeyboardRecordsThatItWasAdded() {
        KeyboardSetupStatusStore.recordExtensionAppearance(
            hasFullAccess: false,
            defaults: defaults
        )

        XCTAssertEqual(
            KeyboardSetupStatusStore.read(defaults: defaults),
            KeyboardSetupStatus(keyboardObserved: true, fullAccessObserved: false)
        )
    }

    func testOpeningKeyboardWithFullAccessCompletesBothSetupSteps() {
        KeyboardSetupStatusStore.recordExtensionAppearance(
            hasFullAccess: true,
            defaults: defaults
        )

        XCTAssertEqual(
            KeyboardSetupStatusStore.read(defaults: defaults),
            KeyboardSetupStatus(keyboardObserved: true, fullAccessObserved: true)
        )
    }

    func testOpeningKeyboardAfterFullAccessIsRevokedClearsThatCompletion() {
        KeyboardSetupStatusStore.recordExtensionAppearance(
            hasFullAccess: true,
            defaults: defaults
        )
        KeyboardSetupStatusStore.recordExtensionAppearance(
            hasFullAccess: false,
            defaults: defaults
        )

        XCTAssertEqual(
            KeyboardSetupStatusStore.read(defaults: defaults),
            KeyboardSetupStatus(keyboardObserved: true, fullAccessObserved: false)
        )
    }
}
