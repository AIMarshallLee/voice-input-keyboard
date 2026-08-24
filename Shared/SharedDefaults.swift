import Foundation

/// App 与键盘扩展共享的偏好存储入口。
///
/// 所有跨进程设置都必须通过同一个 App Group suite 访问。各管理器仍允许
/// 注入独立的 `UserDefaults`，便于单元测试使用隔离的 suite。
enum SharedDefaults {
    static let suiteName = "group.com.daseanle.votype.container"

    static let shared: UserDefaults = make()

    static func make(suiteName: String = SharedDefaults.suiteName) -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            assertionFailure("Unable to create UserDefaults suite: \(suiteName)")
            return .standard
        }
        return defaults
    }
}
