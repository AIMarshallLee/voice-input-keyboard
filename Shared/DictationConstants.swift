import Foundation

/// 键盘扩展与宿主 App 的 URL Scheme 降级入口。
///
/// URL 只携带不可猜测的会话 UUID；语言、选中文本和功能设置始终留在
/// App Group 共享容器中，避免自定义 scheme 暴露用户内容或产生两份设置快照。
enum DictationConstants {
    static let urlScheme = "votype"
    static let dictationPath = "dictation"
    static let paramSession = "session"

    static func buildDictationURL(session: String) -> URL? {
        guard UUID(uuidString: session) != nil else { return nil }
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = dictationPath
        components.queryItems = [
            URLQueryItem(name: paramSession, value: session)
        ]
        return components.url
    }
}
