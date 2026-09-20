import XCTest
@testable import VoiceInputApp

@MainActor
final class DictationHotAckCoordinatorTests: XCTestCase {
    func testHotAcknowledgementCancelsOnePointTwoSecondFallback() {
        let scheduler = RecordingKeyboardLaunchScheduler()
        let coordinator = DictationHotAckCoordinator(scheduler: scheduler)
        let token = SessionToken()
        var timedOut: [SessionToken] = []
        coordinator.arm(token: token) { timedOut.append($0) }
        XCTAssertEqual(scheduler.scheduledIntervals, [1.2])
        XCTAssertTrue(coordinator.acknowledge(token: token))
        scheduler.fireAll()
        XCTAssertTrue(timedOut.isEmpty)
        XCTAssertFalse(coordinator.acknowledge(token: token))
    }

    func testHotTimeoutMarksOnlyArmedTokenOnceAndRejectsLateAcknowledgement() {
        let scheduler = RecordingKeyboardLaunchScheduler()
        let coordinator = DictationHotAckCoordinator(scheduler: scheduler)
        let token = SessionToken()
        var timedOut: [SessionToken] = []
        coordinator.arm(token: token) { timedOut.append($0) }
        XCTAssertFalse(coordinator.acknowledge(token: SessionToken()))
        scheduler.fireAll()
        scheduler.fireAll()
        XCTAssertEqual(timedOut, [token])
        XCTAssertFalse(coordinator.acknowledge(token: token))
    }

    func testRearmingAndCancellationInvalidateEvenAlreadyQueuedCallbacks() {
        let scheduler = RecordingKeyboardLaunchScheduler()
        let coordinator = DictationHotAckCoordinator(scheduler: scheduler)
        let old = SessionToken()
        let current = SessionToken()
        var timedOut: [SessionToken] = []
        coordinator.arm(token: old) { timedOut.append($0) }
        let staleCallback = scheduler.tasks[0].action
        coordinator.arm(token: current) { timedOut.append($0) }
        staleCallback()
        XCTAssertFalse(coordinator.acknowledge(token: old))
        XCTAssertTrue(timedOut.isEmpty)
        coordinator.cancel()
        scheduler.fireAll()
        scheduler.tasks[1].action()
        XCTAssertTrue(timedOut.isEmpty)
        XCTAssertFalse(coordinator.acknowledge(token: current))
    }
}

@MainActor
private final class RecordingKeyboardLaunchScheduler: KeyboardLaunchScheduling {
    private(set) var scheduledIntervals: [TimeInterval] = []
    private(set) var tasks: [RecordingKeyboardLaunchTask] = []

    func schedule(after interval: TimeInterval, action: @escaping () -> Void) -> any KeyboardLaunchScheduledTask {
        scheduledIntervals.append(interval)
        let task = RecordingKeyboardLaunchTask(action: action)
        tasks.append(task)
        return task
    }

    func fireAll() {
        // Retain callbacks to exercise duplicate timer delivery as well as cancellation.
        for task in tasks where !task.isCancelled { task.action() }
    }
}

@MainActor
private final class RecordingKeyboardLaunchTask: KeyboardLaunchScheduledTask {
    let action: () -> Void
    private(set) var isCancelled = false
    init(action: @escaping () -> Void) { self.action = action }
    func cancel() { isCancelled = true }
}
