import Foundation

/// 宿主 App 的深链入口。键盘先保存不可猜测的会话，再由用户点击的
/// 麦克风动作请求系统打开该 URL。
///
/// URL 只携带不可猜测的会话 UUID；语言、选中文本和功能设置始终留在
/// App Group 共享容器中，避免自定义 scheme 暴露用户内容或产生两份设置快照。
enum DictationConstants {
    static let urlScheme = "votype"
    static let dictationPath = "dictation"
    static let paramSession = "session"

    static func isValidSession(_ session: String) -> Bool {
        UUID(uuidString: session) != nil
    }

    static func buildDictationURL(session: String) -> URL? {
        guard isValidSession(session) else { return nil }
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = dictationPath
        components.queryItems = [
            URLQueryItem(name: paramSession, value: session)
        ]
        return components.url
    }
}
