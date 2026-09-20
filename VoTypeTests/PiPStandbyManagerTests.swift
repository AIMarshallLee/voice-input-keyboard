import XCTest
@testable import VoiceInputApp

@MainActor
final class PiPStandbyManagerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        DarwinBridge.setContainerDirectoryForTesting(directory)
    }

    override func tearDownWithError() throws {
        DarwinBridge.resetContainerDirectoryAfterTesting()
        try FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

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

    func testManualStopNotifiesOnceIncludingWhenControllerAlreadyInactive() {
        for alreadyInactive in [false, true] {
            let controller = FakeController()
            let manager = PiPStandbyManager(controller: controller, isSupported: true)
            defer { manager.stopStandby() }
            controller.isPictureInPictureActive = true
            manager.handleDidStart()
            var losses = 0
            manager.onStandbyStopped = { losses += 1 }
            if alreadyInactive { controller.isPictureInPictureActive = false }
            manager.stopStandby()
            XCTAssertEqual(losses, 1)
            XCTAssertEqual(manager.state, .ready)
            XCTAssertNil(DarwinBridge.readReadiness())
            controller.isPictureInPictureActive = false
            manager.handleDidStop()
            manager.stopStandby()
            XCTAssertEqual(losses, 1)
        }
    }

    func testSystemStopNotifiesOnceForEveryPresentedState() {
        for phase in 0..<3 {
            let controller = FakeController()
            let manager = PiPStandbyManager(controller: controller, isSupported: true)
            defer { manager.stopStandby() }
            controller.isPictureInPictureActive = true
            manager.handleDidStart()
            if phase == 1 { manager.setRecording(text: "text") }
            if phase == 2 { manager.setProcessing(text: "text") }
            var losses = 0
            manager.onStandbyStopped = { losses += 1 }
            controller.isPictureInPictureActive = false
            manager.handleDidStop()
            manager.handleDidStop()
            XCTAssertEqual(losses, 1)
            XCTAssertEqual(manager.state, .ready)
            XCTAssertNil(DarwinBridge.readReadiness())
        }
    }

    func testLateOldStopDelegateCannotInterruptNewerStartingOrActivePiP() {
        let controller = FakeController()
        let manager = PiPStandbyManager(controller: controller, isSupported: true)
        defer { manager.stopStandby() }
        controller.isPictureInPictureActive = true
        manager.handleDidStart()
        manager.stopStandby()
        controller.isPictureInPictureActive = false
        var losses = 0
        manager.onStandbyStopped = { losses += 1 }
        manager.startStandby()
        manager.handleDidStop()
        XCTAssertEqual(manager.state, .starting)
        XCTAssertEqual(losses, 0)
        controller.isPictureInPictureActive = true
        manager.handleDidStart()
        manager.setRecording(text: "new session")
        manager.handleDidStop()
        XCTAssertEqual(manager.state, .recording(text: "new session"))
        XCTAssertNotNil(DarwinBridge.readReadiness())
        XCTAssertEqual(losses, 0)
    }

    func testStartupFailureAndTimeoutDoNotReportLossOfActiveSession() {
        for timeout in [false, true] {
            let controller = FakeController()
            let manager = PiPStandbyManager(controller: controller, isSupported: true)
            defer { manager.stopStandby() }
            var losses = 0
            manager.onStandbyStopped = { losses += 1 }
            manager.handleDidStop()
            manager.startStandby()
            if timeout {
                manager.handleStartupDeadline(elapsed: PiPLaunchPolicy.startupTimeout)
            } else {
                manager.handleFailedToStart(message: "system rejected")
            }
            let failure = manager.state
            manager.handleDidStop()
            XCTAssertEqual(manager.state, failure)
            XCTAssertEqual(losses, 0)
            XCTAssertNil(DarwinBridge.readReadiness())
        }
    }
}
