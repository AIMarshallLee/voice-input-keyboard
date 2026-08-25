import Foundation

enum DictationLaunchAction: Equatable {
    case requestInPlace
    case openContainingApp
    case wait
    case showManualRecovery
}

/// 语音入口的时间边界。把热路径与降级规则从 UIKit timer 中抽出来，确保
/// “无响应”永远有确定的下一步，而不是由某个回调碰运气。
struct DictationLaunchPolicy {
    static let inPlaceResponseDeadline: TimeInterval = 1.2
    static let manualRecoveryDeadline: TimeInterval = 3.0

    static func initialAction(canStartInPlace: Bool) -> DictationLaunchAction {
        canStartInPlace ? .requestInPlace : .openContainingApp
    }

    static func actionAfterNoResponse(
        elapsed: TimeInterval,
        initialAction: DictationLaunchAction
    ) -> DictationLaunchAction {
        if elapsed >= manualRecoveryDeadline {
            return .showManualRecovery
        }
        if initialAction == .requestInPlace,
           elapsed >= inPlaceResponseDeadline {
            return .openContainingApp
        }
        return .wait
    }
}
