import Foundation
import UIKit
import CoreFoundation

/// 键盘扩展与容器 App 之间通信的共享常量
/// iOS 键盘扩展无法直接录音(平台限制)
/// 通过 URL 参数(传设置) + 命名剪贴板(传结果) + Darwin 通知(传信号) 实现跨进程通信
/// 不使用 App Group,避免 provisioning profile 问题
enum DictationConstants {
    // MARK: - URL Scheme
    static let urlScheme = "votype"
    static let dictationPath = "dictation"

    // MARK: - Darwin 通知 (仅信号,不携带数据)
    static let darwinNotificationName = "com.daseanle.votype.dictationComplete" as CFString

    // MARK: - 命名剪贴板 (跨进程传结果)
    static let pasteboardName = "com.daseanle.votype.result"

    // MARK: - 剪贴板数据格式 (JSON)
    // {"status":"completed","text":"识别结果","session":"UUID"}
    // {"status":"error","error":"错误信息","session":"UUID"}
    static let statusCompleted = "completed"
    static let statusError = "error"

    // MARK: - URL 参数 Keys
    static let paramLang = "lang"
    static let paramWhisper = "whisper"
    static let paramTranslate = "translate"
    static let paramTranslateTarget = "translateTarget"
    static let paramSelectedText = "selectedText"
    static let paramKbType = "kbType"
    static let paramSession = "session"

    // MARK: - 构建听写 URL
    static func buildDictationURL(
        language: String,
        whisper: Bool,
        translateEnabled: Bool,
        translateTarget: String,
        selectedText: String?,
        keyboardType: Int,
        session: String
    ) -> URL? {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = dictationPath

        var items: [URLQueryItem] = [
            URLQueryItem(name: paramLang, value: language),
            URLQueryItem(name: paramWhisper, value: whisper ? "1" : "0"),
            URLQueryItem(name: paramTranslate, value: translateEnabled ? "1" : "0"),
            URLQueryItem(name: paramTranslateTarget, value: translateTarget),
            URLQueryItem(name: paramKbType, value: String(keyboardType)),
            URLQueryItem(name: paramSession, value: session)
        ]

        if let selected = selectedText, !selected.isEmpty {
            items.append(URLQueryItem(name: paramSelectedText, value: selected))
        }

        components.queryItems = items
        return components.url
    }

    // MARK: - 剪贴板读写
    static func writeResult(text: String, session: String) {
        let payload: [String: String] = [
            "status": statusCompleted,
            "text": text,
            "session": session
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let pb = UIPasteboard(name: UIPasteboard.Name(rawValue: pasteboardName), create: true)
        pb?.string = json
    }

    static func writeError(message: String, session: String) {
        let payload: [String: String] = [
            "status": statusError,
            "error": message,
            "session": session
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let pb = UIPasteboard(name: UIPasteboard.Name(rawValue: pasteboardName), create: true)
        pb?.string = json
    }

    /// 读取并消费剪贴板结果,返回 (text?, error?)
    static func readAndConsumeResult() -> (text: String?, error: String?) {
        guard let pb = UIPasteboard(name: UIPasteboard.Name(rawValue: pasteboardName), create: false),
              let json = pb.string,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return (nil, nil)
        }

        // 清除剪贴板
        pb.string = ""

        let status = dict["status"] ?? ""
        if status == statusCompleted {
            return (dict["text"], nil)
        } else if status == statusError {
            return (nil, dict["error"])
        }
        return (nil, nil)
    }

    // MARK: - 发送 Darwin 通知
    static func postDarwinNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotificationCenter(),
            CFNotificationName(darwinNotificationName),
            nil, nil, true
        )
    }
}
