import Foundation
import UIKit

/// Darwin 通知 + 命名剪贴板 IPC 系统 (Build 16)
/// 完全不依赖 App Group,使用 Darwin 通知传信号 + 命名剪贴板传数据
///
/// 通信流程:
/// 1. 键盘写设置到剪贴板 -> 发 Darwin 通知 requestStartDictation
/// 2. 主 App 收到通知 -> 读剪贴板设置 -> 开始录音 -> 发 Darwin 通知 dictationStarted
/// 3. 主 App 录音完成 -> 写结果到剪贴板 -> 发 Darwin 通知 transcriptionReady
/// 4. 键盘收到通知 -> 读剪贴板 -> 插入文字
///
/// 心跳机制:
/// 主 App 录音时每 0.5s 发一次 heartbeat Darwin 通知
/// 键盘在内存中记录最后一次收到心跳的时间
/// 如果心跳新鲜(3s 内),走 Path A (Darwin 通知,不切 App)
/// 如果心跳过期,走 Path B (URL Scheme,启动主 App)

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
    /// 主 App -> 键盘:心跳 (每 0.5s 发一次,表示主 App 存活)
    static let heartbeat = "com.daseanle.votype.heartbeat"
}

// MARK: - Darwin 通知观察者

/// 跨进程通知观察者
/// CFNotificationCenter 的 Darwin 通知中心,不传递数据(仅信号)
/// 数据通过命名剪贴板传递
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

// MARK: - 心跳追踪器

/// 在键盘扩展内存中追踪主 App 心跳
/// 主 App 每 0.5s 发一次 heartbeat Darwin 通知
/// 键盘收到后更新 lastHeartbeatTime
/// isMainAppAlive() 检查 lastHeartbeatTime 是否在 3s 内
class HeartbeatTracker {
    static let shared = HeartbeatTracker()

    /// 用 NSLock 保证线程安全 (Darwin 通知回调可能在子线程)
    private let lock = NSLock()
    private var lastHeartbeatTime: CFAbsoluteTime = 0

    private var observer: DarwinNotificationObserver?

    private init() {
        // 监听心跳通知
        observer = DarwinNotificationObserver(name: DarwinNotificationName.heartbeat) { [weak self] in
            self?.updateHeartbeat()
        }
    }

    private func updateHeartbeat() {
        lock.lock()
        lastHeartbeatTime = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    /// 主 App 是否存活 (3s 内收到过心跳)
    func isMainAppAlive(threshold: TimeInterval = 3.0) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard lastHeartbeatTime > 0 else { return false }
        let age = CFAbsoluteTimeGetCurrent() - lastHeartbeatTime
        return age < threshold
    }

    /// 心跳年龄 (秒)
    func heartbeatAge() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard lastHeartbeatTime > 0 else { return .infinity }
        return CFAbsoluteTimeGetCurrent() - lastHeartbeatTime
    }
}

// MARK: - 命名剪贴板

/// 命名剪贴板管理
/// iOS 命名剪贴板可在进程间共享,适合传递少量数据
enum SharedClipboard {
    /// 结果剪贴板 (转录文本 + 错误信息)
    static let resultName = UIPasteboard.Name("com.daseanle.votype.result")
    /// 设置剪贴板 (听写设置 JSON)
    static let settingsName = UIPasteboard.Name("com.daseanle.votype.settings")

    static var resultPasteboard: UIPasteboard? {
        UIPasteboard(name: resultName, create: false)
    }

    static var settingsPasteboard: UIPasteboard? {
        UIPasteboard(name: settingsName, create: false)
    }
}

// MARK: - 跨进程通信桥梁

/// 键盘扩展 <-> 主 App 的 IPC 桥梁
/// Darwin 通知传信号 + 命名剪贴板传数据
/// 不依赖 App Group
struct DarwinBridge {

    // MARK: - 写入转录结果(主 App 调用)

    static func writeTranscription(_ text: String, session: String, deleteSelected: Bool = false) {
        let payload: [String: String] = [
            "status": "completed",
            "text": text,
            "session": session,
            "deleteSelected": deleteSelected ? "1" : "0"
        ]
        writeJSON(payload, to: .result)
        DarwinNotificationObserver.post(DarwinNotificationName.transcriptionReady)
        print("[DarwinBridge] Transcription written, session=" + String(session.prefix(8)))
    }

    // MARK: - 写入错误(主 App 调用)

    static func writeError(_ message: String, session: String) {
        let payload: [String: String] = ["status": "error", "text": message, "session": session]
        writeJSON(payload, to: .result)
        DarwinNotificationObserver.post(DarwinNotificationName.transcriptionError)
        print("[DarwinBridge] Error written: " + message)
    }

    // MARK: - 读取并消费结果(键盘扩展调用)

    static func readAndConsumeResult() -> (text: String?, error: String?, session: String?, deleteSelected: Bool) {
        guard let pb = SharedClipboard.resultPasteboard,
              let json = pb.string,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return (nil, nil, nil, false)
        }

        // 消费后清空剪贴板
        pb.string = ""

        let status = dict["status"] ?? ""
        if status == "completed" {
            let del = dict["deleteSelected"] == "1"
            return (dict["text"], nil, dict["session"], del)
        } else if status == "error" {
            return (nil, dict["text"], dict["session"], false)
        }
        return (nil, nil, nil, false)
    }

    // MARK: - 心跳机制

    /// 主 App 调用:发送心跳通知
    static func writeHeartbeat() {
        DarwinNotificationObserver.post(DarwinNotificationName.heartbeat)
    }

    /// 键盘调用:检查主 App 是否存活
    static func isMainAppAlive(threshold: TimeInterval = 3.0) -> Bool {
        HeartbeatTracker.shared.isMainAppAlive(threshold: threshold)
    }

    /// 键盘调用:心跳年龄
    static func heartbeatAge() -> TimeInterval {
        HeartbeatTracker.shared.heartbeatAge()
    }

    // MARK: - 听写设置(键盘 -> 主 App)

    static func writeDictationSettings(_ settings: DictationSettings) {
        guard let data = try? JSONEncoder().encode(settings),
              let json = String(data: data, encoding: .utf8) else { return }
        let pb = UIPasteboard(name: SharedClipboard.settingsName, create: true)
        pb?.string = json
    }

    static func readDictationSettings() -> DictationSettings? {
        guard let pb = SharedClipboard.settingsPasteboard,
              let json = pb.string,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DictationSettings.self, from: data)
    }

    // MARK: - 发送 Darwin 通知

    static func postNotification(_ name: String) {
        DarwinNotificationObserver.post(name)
    }

    // MARK: - 私有:JSON 读写

    private enum ClipboardType {
        case result
        case settings
    }

    private static func writeJSON(_ payload: [String: String], to type: ClipboardType) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let name: UIPasteboard.Name
        switch type {
        case .result:
            name = SharedClipboard.resultName
        case .settings:
            name = SharedClipboard.settingsName
        }
        let pb = UIPasteboard(name: name, create: true)
        pb?.string = json
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
