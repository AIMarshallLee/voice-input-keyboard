import XCTest
@testable import VoiceInputApp

@MainActor
final class PiPStandbyManagerTests: XCTestCase {
    @MainActor
    private final class FakeController: PiPControlling {
        var isPictureInPictureActive = false
        var isPictureInPicturePossible = true
        private(set) var startCount = 0
        private(set) var stopCount = 0
        private(set) var invalidateCount = 0

        func startPictureInPicture() {
            startCount += 1
        }

        func stopPictureInPicture() {
            stopCount += 1
        }

        func invalidatePlaybackState() {
            invalidateCount += 1
        }
    }

    func testInactiveControllerCannotRemainStartingAfterDeadline() {
        let controller = FakeController()
        let manager = PiPStandbyManager(controller: controller, isSupported: true)

        manager.startStandby()
        XCTAssertEqual(manager.state, .starting)
        XCTAssertEqual(controller.startCount, 1)

        manager.handleStartupDeadline(elapsed: PiPLaunchPolicy.startupTimeout)

        guard case .failed = manager.state else {
            return XCTFail("An inactive controller must leave the starting state")
        }
        XCTAssertTrue(manager.canToggleStandby)
    }

    func testAvailabilityRecoveryReenablesStandbyControl() {
        let controller = FakeController()
        controller.isPictureInPicturePossible = false
        let manager = PiPStandbyManager(controller: controller, isSupported: true)

        manager.startStandby()
        guard case .failed = manager.state else {
            return XCTFail("An unavailable controller must fail before starting")
        }
        XCTAssertFalse(manager.canToggleStandby)

        controller.isPictureInPicturePossible = true
        manager.updateStartAvailability(true)

        XCTAssertEqual(manager.state, .ready)
        XCTAssertTrue(manager.canToggleStandby)
    }

    func testDidStartWinsAgainstLateWatchdog() {
        defer { DarwinBridge.clearReadiness() }
        let controller = FakeController()
        let manager = PiPStandbyManager(controller: controller, isSupported: true)

        manager.startStandby()
        controller.isPictureInPictureActive = true
        manager.handleDidStart()
        manager.handleStartupDeadline(elapsed: PiPLaunchPolicy.startupTimeout + 1)

        XCTAssertEqual(manager.state, .standby)
    }

    func testExplicitFailureWinsAgainstLateWatchdog() {
        let controller = FakeController()
        let manager = PiPStandbyManager(controller: controller, isSupported: true)

        manager.startStandby()
        manager.handleFailedToStart(message: "system rejected")
        manager.handleStartupDeadline(elapsed: PiPLaunchPolicy.startupTimeout + 1)

        XCTAssertEqual(manager.state, .failed(message: "system rejected"))
        XCTAssertTrue(manager.canToggleStandby)
    }

    func testStopClearsStandbyAndKeepsControlRetryable() {
        defer { DarwinBridge.clearReadiness() }
        let controller = FakeController()
        let manager = PiPStandbyManager(controller: controller, isSupported: true)

        manager.startStandby()
        controller.isPictureInPictureActive = true
        manager.handleDidStart()
        manager.stopStandby()
        controller.isPictureInPictureActive = false

        XCTAssertEqual(controller.stopCount, 1)
        XCTAssertEqual(manager.state, .ready)
        XCTAssertTrue(manager.canToggleStandby)
        XCTAssertNil(DarwinBridge.readReadiness())
    }
}
