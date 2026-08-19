import Foundation

/// 键盘扩展与容器 App 之间通信的共享常量
/// iOS 键盘扩展无法直接录音(平台限制)
/// 通过 App Group + Darwin 通知实现跨进程通信
enum DictationConstants {
    // MARK: - App Group
    static let appGroupID = "group.com.voiceinput.shared"

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    // MARK: - URL Scheme
    static let urlScheme = "votype"
    static let dictationURL = "votype://dictation"

    // MARK: - Darwin 通知
    static let darwinNotificationName = "com.daseanle.votype.dictationComplete" as CFString

    // MARK: - App Group Keys
    /// 当前会话 ID (String, 每次启动唯一)
    static let sessionIdKey = "dictation_sessionId"
    /// 会话状态 (String: pending/recording/completed/error/consumed)
    static let statusKey = "dictation_status"
    /// 识别结果文本 (String)
    static let resultKey = "dictation_result"
    /// 错误信息 (String)
    static let errorMessageKey = "dictation_errorMessage"
    /// 语音识别语言 ID (String, e.g. "zh-CN", "en-US")
    static let languageKey = "dictation_language"
    /// 耳语模式 (Bool)
    static let whisperModeKey = "dictation_whisperMode"
    /// 翻译模式开启 (Bool)
    static let translationEnabledKey = "dictation_translationEnabled"
    /// 翻译目标语言 ID (String)
    static let translationTargetIDKey = "dictation_translationTargetID"
    /// 选中的文本 (String?, 用于语音编辑)
    static let selectedTextKey = "dictation_selectedText"
    /// 键盘类型 (Int, rawValue, 用于场景感知)
    static let keyboardTypeKey = "dictation_keyboardType"

    // MARK: - Status Values
    static let statusPending = "pending"
    static let statusRecording = "recording"
    static let statusCompleted = "completed"
    static let statusError = "error"
    static let statusConsumed = "consumed"
}
