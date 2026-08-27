import Foundation

enum PiPLaunchFailure: Equatable {
    case unsupported
    case currentlyUnavailable
}

enum PiPLaunchDecision: Equatable {
    case start
    case fail(PiPLaunchFailure)
}

enum PiPLaunchPolicy {
    static let startupTimeout: TimeInterval = 4

    static func initialDecision(
        isSupported: Bool,
        isPossible: Bool
    ) -> PiPLaunchDecision {
        guard isSupported else { return .fail(.unsupported) }
        guard isPossible else { return .fail(.currentlyUnavailable) }
        return .start
    }

    static func didStartupTimeOut(
        elapsed: TimeInterval,
        isActive: Bool
    ) -> Bool {
        !isActive && elapsed >= startupTimeout
    }
}
