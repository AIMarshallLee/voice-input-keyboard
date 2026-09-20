import Foundation

@MainActor
protocol KeyboardLaunchScheduledTask: AnyObject {
    func cancel()
}

@MainActor
protocol KeyboardLaunchScheduling: AnyObject {
    func schedule(after interval: TimeInterval, action: @escaping () -> Void) -> any KeyboardLaunchScheduledTask
}

@MainActor
final class TimerKeyboardLaunchScheduler: KeyboardLaunchScheduling {
    func schedule(after interval: TimeInterval, action: @escaping () -> Void) -> any KeyboardLaunchScheduledTask {
        TimerKeyboardLaunchTask(timer: Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            action()
        })
    }
}

@MainActor
private final class TimerKeyboardLaunchTask: KeyboardLaunchScheduledTask {
    private let timer: Timer
    init(timer: Timer) { self.timer = timer }
    func cancel() { timer.invalidate() }
    deinit { timer.invalidate() }
}

@MainActor
final class DictationHotAckCoordinator {
    private let scheduler: any KeyboardLaunchScheduling
    private var armedToken: SessionToken?
    private var task: (any KeyboardLaunchScheduledTask)?

    init(scheduler: any KeyboardLaunchScheduling) { self.scheduler = scheduler }

    func arm(token: SessionToken, onTimeout: @escaping (SessionToken) -> Void) {
        cancel()
        armedToken = token
        task = scheduler.schedule(after: DictationLaunchPolicy.inPlaceResponseDeadline) { [weak self] in
            guard let self, self.armedToken == token else { return }
            self.task = nil
            self.armedToken = nil
            onTimeout(token)
        }
    }

    @discardableResult
    func acknowledge(token: SessionToken) -> Bool {
        guard armedToken == token else { return false }
        cancel()
        return true
    }

    func cancel() {
        task?.cancel()
        task = nil
        armedToken = nil
    }
}
