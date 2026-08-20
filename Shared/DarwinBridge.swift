import Foundation
import UIKit

/// Darwin 通知 + App Group 文件 IPC 系统
/// 替代命名剪贴板轮询,实现实时跨进程通信
/// 参考 Sayboard 架构:Darwin 通知传信号 + App Group 文件传数据
///
/// 通信流程:
/// 1. 键盘写设置到 UserDefaults -> 发 Darwin 通知 requestStartDictation
/// 2. 主 App 收到通知 -> 读设置 -> 开始录音 -> 发 Darwin 通知 dictationStarted
/// 3. 主 App 录音完成 -> 写结果到 App Group 文件 -> 发 Darwin 通知 transcriptionReady
/// 4. 键盘收到通知 -> 读文件 -> 插入文字
///
/// 降级路径:
/// - 如果主 App 心跳过期(被系统杀掉),键盘直接 URL Scheme 启动主 App
/// - 如果 App Group 不可用(provisioning 未配置),自动降级到命名剪贴板传数据

// MARK: - Darwin 通知名称

enum DarwinNotificationName {
    /// 键盘 -> 主 App:请求开始听写
    static let requestStartDictation = "com.daseanle.votype.requestStartDictation"
    /// 主 App -> 键盘:听写已开始
    static let dictationStarted = "com.daseanle.votype.dictationStarted"
    /// 主 App -> 键盘:听写已停止
    static let dictationStopped = "com.daseanle.votype.dictationStopped"
    /// 键盘 -> 主 App:请求停止听写
    static let requestStopDictation = "com.daseanle.votype.requestStopDictation"
    /// 主 App -> 键盘:转录结果已就绪
    static let transcriptionReady = "com.daseanle.votype.transcriptionReady"
    /// 主 App -> 键盘:出错
    static let transcriptionError = "com.daseanle.votype.transcriptionError"
}

// MARK: - Darwin 通知观察者

/// 跨进程通知观察者
/// CFNotificationCenter 的 Darwin 通知中心,不传递数据(仅信号)
/// 数据通过 App Group 文件/UserDefaults 传递
final class DarwinNotificationObserver {

    private let callback: () -> Void
    private let name: String
    private var observer: UnsafeMutableRawPointer?

    init(name: String, callback: @escaping () -> Void) {
        self.name = name
        self.callback = callback

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observerPtr = Unmanaged.passRetained(self).toOpaque()
        self.observer = observerPtr

        CFNotificationCenterAddObserver(
            center,
            observerPtr,
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let obj = Unmanaged<DarwinNotificationObserver>.fromOpaque(observer).takeUnretainedValue()
                if Thread.isMainThread {
                    obj.callback()
                } else {
                    DispatchQueue.main.async { obj.callback() }
                }
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        if let observer = self.observer {
            CFNotificationCenterRemoveObserver(
                center,
                observer,
                CFNotificationName(name as CFString),
                nil
            )
            Unmanaged<DarwinNotificationObserver>.fromOpaque(observer).release()
        }
    }

    static func post(_ name: String) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }
}

// MARK: - App Group 共享存储

enum AppGroup {
    static let identifier = "group.com.daseanle.votype.shared"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }
}

// MARK: - 跨进程通信桥梁

/// 键盘扩展 <-> 主 App 的 IPC 桥梁
/// 优先使用 App Group 文件,Darwin 通知传递信号
/// App Group 不可用时降级到命名剪贴板
struct DarwinBridge {

    // MARK: - 文件名

    private static let transcriptionFileName = "transcription.txt"
    private static let errorFileName = "error.txt"

    // MARK: - UserDefaults Keys

    private static let heartbeatKey = "mainAppHeartbeat"
    private static let sessionTokenKey = "sessionToken"
    private static let settingsKey = "dictationSettings"

    // MARK: - 剪贴板降级 (App Group 不可用时)

    private static let clipboardName = "com.daseanle.votype.result"

    // MARK: - 文件 URL

    private static var transcriptionFileURL: URL? {
        AppGroup.containerURL?.appendingPathComponent(transcriptionFileName)
    }

    private static var errorFileURL: URL? {
        AppGroup.containerURL?.appendingPathComponent(errorFileName)
    }

    // MARK: - 写入转录结果(主 App 调用)

    static func writeTranscription(_ text: String, session: String) {
        if let url = transcriptionFileURL {
            let payload = session + "\n" + text
            try? Data(payload.utf8).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        } else {
            writeClipboardResult(status: "completed", text: text, session: session)
        }
        DarwinNotificationObserver.post(DarwinNotificationName.transcriptionReady)
        print("[DarwinBridge] Transcription written, session=" + String(session.prefix(8)))
    }

    // MARK: - 写入错误(主 App 调用)

    static func writeError(_ message: String, session: String) {
        if let url = errorFileURL {
            let payload = session + "\n" + message
            try? Data(payload.utf8).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        } else {
            writeClipboardResult(status: "error", text: message, session: session)
        }
        DarwinNotificationObserver.post(DarwinNotificationName.transcriptionError)
        print("[DarwinBridge] Error written: " + message)
    }

    // MARK: - 剪贴板降级读写

    private static func writeClipboardResult(status: String, text: String, session: String) {
        let payload: [String: String] = ["status": status, "text": text, "session": session]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            let pb = UIPasteboard(name: UIPasteboard.Name(rawValue: clipboardName), create: true)
            pb?.string = json
        }
    }

    private static func readClipboardResult() -> (text: String?, error: String?, session: String?) {
        guard let pb = UIPasteboard(name: UIPasteboard.Name(rawValue: clipboardName), create: false),
              let json = pb.string,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return (nil, nil, nil)
        }
        pb.string = ""
        let status = dict["status"] ?? ""
        if status == "completed" {
            return (dict["text"], nil, dict["session"])
        } else if status == "error" {
            return (nil, dict["text"], dict["session"])
        }
        return (nil, nil, nil)
    }

    // MARK: - 读取并消费结果(键盘扩展调用)

    static func readAndConsumeResult() -> (text: String?, error: String?, session: String?) {
        // 优先 App Group 文件
        if let url = transcriptionFileURL,
           FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let content = String(data: data, encoding: .utf8) {
            let lines = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let session = lines.first.map(String.init)
            let text = lines.count > 1 ? String(lines[1]) : ""
            try? FileManager.default.removeItem(at: url)
            return (text, nil, session)
        }

        if let url = errorFileURL,
           FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let content = String(data: data, encoding: .utf8) {
            let lines = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let session = lines.first.map(String.init)
            let message = lines.count > 1 ? String(lines[1]) : ""
            try? FileManager.default.removeItem(at: url)
            return (nil, message, session)
        }

        // 降级:命名剪贴板
        return readClipboardResult()
    }

    // MARK: - 心跳机制

    static func writeHeartbeat() {
        AppGroup.sharedDefaults?.set(CFAbsoluteTimeGetCurrent(), forKey: heartbeatKey)
    }

    static func isMainAppAlive(threshold: TimeInterval = 3.0) -> Bool {
        guard let heartbeat = AppGroup.sharedDefaults?.double(forKey: heartbeatKey) else {
            return false
        }
        guard heartbeat > 0 else { return false }
        let age = CFAbsoluteTimeGetCurrent() - heartbeat
        return age < threshold
    }

    static func heartbeatAge() -> TimeInterval {
        guard let heartbeat = AppGroup.sharedDefaults?.double(forKey: heartbeatKey),
              heartbeat > 0 else {
            return .infinity
        }
        return CFAbsoluteTimeGetCurrent() - heartbeat
    }

    // MARK: - Session Token

    static func writeSessionToken(_ token: String) {
        AppGroup.sharedDefaults?.set(token, forKey: sessionTokenKey)
    }

    static func readSessionToken() -> String? {
        AppGroup.sharedDefaults?.string(forKey: sessionTokenKey)
    }

    // MARK: - 听写设置(键盘 -> 主 App)

    static func writeDictationSettings(_ settings: DictationSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        AppGroup.sharedDefaults?.set(data, forKey: settingsKey)
    }

    static func readDictationSettings() -> DictationSettings? {
        guard let data = AppGroup.sharedDefaults?.data(forKey: settingsKey) else { return nil }
        return try? JSONDecoder().decode(DictationSettings.self, from: data)
    }

    // MARK: - 发送 Darwin 通知

    static func postNotification(_ name: String) {
        DarwinNotificationObserver.post(name)
    }
}

// MARK: - 听写设置(跨进程传递)

struct DictationSettings: Codable {
    let language: String
    let whisper: Bool
    let translateEnabled: Bool
    let translateTarget: String
    let selectedText: String?
    let keyboardType: Int
    let session: String
}
