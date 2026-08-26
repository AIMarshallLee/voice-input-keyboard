import XCTest
@testable import VoiceInputApp

final class PiPLaunchPolicyTests: XCTestCase {
    func testUnsupportedDeviceFailsBeforeStarting() {
        XCTAssertEqual(
            PiPLaunchPolicy.initialDecision(isSupported: false, isPossible: false),
            .fail(.unsupported)
        )
    }

    func testCurrentlyUnavailableControllerFailsBeforeStarting() {
        XCTAssertEqual(
            PiPLaunchPolicy.initialDecision(isSupported: true, isPossible: false),
            .fail(.currentlyUnavailable)
        )
    }

    func testPossibleControllerMayStart() {
        XCTAssertEqual(
            PiPLaunchPolicy.initialDecision(isSupported: true, isPossible: true),
            .start
        )
    }

    func testInactiveControllerFailsAtStartupDeadline() {
        XCTAssertTrue(
            PiPLaunchPolicy.didStartupTimeOut(
                elapsed: PiPLaunchPolicy.startupTimeout,
                isActive: false
            )
        )
    }

    func testActiveControllerNeverFailsStartupDeadline() {
        XCTAssertFalse(
            PiPLaunchPolicy.didStartupTimeOut(
                elapsed: PiPLaunchPolicy.startupTimeout + 1,
                isActive: true
            )
        )
    }
}
