import Foundation
import UIKit

/// 键盘扩展与容器 App 之间通信的共享常量
///
/// Build 16 起,通信架构改为 Darwin 通知 + 命名剪贴板 (DarwinBridge.swift)
/// 不依赖 App Group,完全使用 Darwin 通知传信号 + 命名剪贴板传数据
/// 本文件仅保留 URL Scheme 构建 (Path B 降级路径使用)
///
/// 通信流程:
/// - 路径 A (首选): Darwin 通知 requestStartDictation → 主 App 录音 → transcriptionReady
/// - 路径 B (降级): URL Scheme 启动主 App → 同上
/// - 结果传递: DarwinBridge.writeTranscription / readAndConsumeResult (命名剪贴板)
enum DictationConstants {
    // MARK: - URL Scheme
    static let urlScheme = "votype"
    static let dictationPath = "dictation"

    // MARK: - URL 参数 Keys (Path B 降级路径使用)
    static let paramLang = "lang"
    static let paramWhisper = "whisper"
    static let paramTranslate = "translate"
    static let paramTranslateTarget = "translateTarget"
    static let paramSelectedText = "selectedText"
    static let paramKbType = "kbType"
    static let paramSession = "session"

    // MARK: - 构建听写 URL (Path B: URL Scheme 降级路径)
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
}
