import Foundation
import CryptoKit

enum DarwinNotificationName {
    static let requestStartDictation = "com.daseanle.votype.requestStartDictation"
    static let dictationStarted = "com.daseanle.votype.dictationStarted"
    static let dictationStopped = "com.daseanle.votype.dictationStopped"
    static let requestStopDictation = "com.daseanle.votype.requestStopDictation"
    static let transcriptionReady = "com.daseanle.votype.transcriptionReady"
    static let transcriptionError = "com.daseanle.votype.transcriptionError"
    static let dictationFailed = "com.daseanle.votype.dictationFailed"
    static let heartbeat = "com.daseanle.votype.heartbeat"
}

/// Darwin 通知只负责发送“有新状态”的信号，业务数据全部放在 App Group 文件中。
final class DarwinNotificationObserver {
    private let callback: () -> Void
    private let name: String
    private var observer: UnsafeMutableRawPointer?

    init(name: String, callback: @escaping () -> Void) {
        self.name = name
        self.callback = callback

        // 调用方强持有观察者；passRetained 会造成无法进入 deinit 的自保持泄漏。
        let observerPointer = Unmanaged.passUnretained(self).toOpaque()
        observer = observerPointer
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observerPointer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let object = Unmanaged<DarwinNotificationObserver>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                if Thread.isMainThread {
                    object.callback()
                } else {
                    DispatchQueue.main.async { object.callback() }
                }
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        if let observer {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                observer,
                CFNotificationName(name as CFString),
                nil
            )
        }
    }

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }
}

final class HeartbeatTracker {
    static let shared = HeartbeatTracker()

    private let lock = NSLock()
    private var lastHeartbeatTime: CFAbsoluteTime = 0
    private var observer: DarwinNotificationObserver?

    private init() {
        observer = DarwinNotificationObserver(name: DarwinNotificationName.heartbeat) { [weak self] in
            self?.updateHeartbeat()
        }
    }

    private func updateHeartbeat() {
        lock.lock()
        lastHeartbeatTime = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    func isMainAppAlive(threshold: TimeInterval = 3.0) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard lastHeartbeatTime > 0 else { return false }
        return CFAbsoluteTimeGetCurrent() - lastHeartbeatTime < threshold
    }

    func heartbeatAge() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard lastHeartbeatTime > 0 else { return .infinity }
        return CFAbsoluteTimeGetCurrent() - lastHeartbeatTime
    }
}

struct DictationSettings: Codable, Equatable {
    let language: String
    let whisper: Bool
    let translateEnabled: Bool
    let translateTarget: String
    let selectedText: String?
    let keyboardType: Int
    let session: String
    let timestamp: TimeInterval

    init(
        language: String,
        whisper: Bool,
        translateEnabled: Bool,
        translateTarget: String,
        selectedText: String?,
        keyboardType: Int,
        session: String,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.language = language
        self.whisper = whisper
        self.translateEnabled = translateEnabled
        self.translateTarget = translateTarget
        self.selectedText = selectedText
        self.keyboardType = keyboardType
        self.session = session
        self.timestamp = timestamp
    }
}

struct DictationIPCResult: Codable, Equatable {
    enum Status: String, Codable {
        case completed
        case error
    }

    let status: Status
    let text: String
    let session: String
    let deleteSelected: Bool
    let timestamp: TimeInterval

    var transcription: String? { status == .completed ? text : nil }
    var error: String? { status == .error ? text : nil }
}

private protocol TimestampedIPCValue {
    var timestamp: TimeInterval { get }
}

extension DictationSettings: TimestampedIPCValue {}
extension DictationIPCResult: TimestampedIPCValue {}

/// App Group 原子文件 IPC。Darwin 通知只传信号，文件承载带 session 的数据。
struct DarwinBridge {
    static let appGroupIdentifier = SharedDefaults.suiteName
    static let settingsMaxAge: TimeInterval = 60
    static let resultMaxAge: TimeInterval = 5 * 60

    private static let settingsFileName = "dictation-settings.json"
    private static let resultFilePrefix = "dictation-result-"
    private static let resultFileSuffix = ".json"
    private static let ioLock = NSLock()
    private static let configurationLock = NSLock()
    private static var injectedContainerDirectory: URL?
    private static var hasInjectedContainerDirectory = false

    // MARK: 测试注入

    static func setContainerDirectoryForTesting(_ directory: URL?) {
        configurationLock.lock()
        injectedContainerDirectory = directory
        hasInjectedContainerDirectory = true
        configurationLock.unlock()
    }

    static func resetContainerDirectoryAfterTesting() {
        configurationLock.lock()
        injectedContainerDirectory = nil
        hasInjectedContainerDirectory = false
        configurationLock.unlock()
    }

    static func clearIPCFilesForTesting() {
        guard let directory = containerDirectory() else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(settingsFileName))
        for url in resultFileURLs(in: directory) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: 结果（主 App -> 键盘）

    @discardableResult
    static func writeTranscription(
        _ text: String,
        session: String,
        deleteSelected: Bool = false,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        guard let fileName = resultFileName(for: session) else { return false }
        let payload = DictationIPCResult(
            status: .completed,
            text: text,
            session: session,
            deleteSelected: deleteSelected,
            timestamp: timestamp
        )
        guard write(payload, fileName: fileName) else { return false }
        DarwinNotificationObserver.post(DarwinNotificationName.transcriptionReady)
        return true
    }

    @discardableResult
    static func writeError(
        _ message: String,
        session: String,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        guard let fileName = resultFileName(for: session) else { return false }
        let payload = DictationIPCResult(
            status: .error,
            text: message,
            session: session,
            deleteSelected: false,
            timestamp: timestamp
        )
        guard write(payload, fileName: fileName) else { return false }
        DarwinNotificationObserver.post(DarwinNotificationName.transcriptionError)
        return true
    }

    /// 只查看结果。扩展重启后用它提示用户，不得直接自动插入。
    static func peekResult(
        now: TimeInterval = Date().timeIntervalSince1970,
        maxAge: TimeInterval = resultMaxAge
    ) -> DictationIPCResult? {
        guard let directory = containerDirectory() else { return nil }
        return resultFileURLs(in: directory)
            .compactMap { url in
                read(
                    fileName: url.lastPathComponent,
                    as: DictationIPCResult.self,
                    now: now,
                    maxAge: maxAge
                )
            }
            .max(by: { $0.timestamp < $1.timestamp })
    }

    /// 仅 session 匹配时原子消费；不匹配时文件保持不变。
    static func readAndConsumeResult(
        expectedSession: String,
        now: TimeInterval = Date().timeIntervalSince1970,
        maxAge: TimeInterval = resultMaxAge
    ) -> DictationIPCResult? {
        guard let fileName = resultFileName(for: expectedSession) else { return nil }
        return consume(
            fileName: fileName,
            as: DictationIPCResult.self,
            expectedSession: expectedSession,
            now: now,
            maxAge: maxAge,
            session: { $0.session },
            timestamp: { $0.timestamp }
        )
    }

    /// 用户确认一个恢复结果后，清理不晚于该结果的其他遗留结果。更晚到达的
    /// 新会话结果会保留，避免扩展重启后旧结果被逐个插入到错误输入框。
    static func discardResults(
        through timestamp: TimeInterval,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        guard let directory = containerDirectory() else { return }
        for url in resultFileURLs(in: directory) {
            guard let result = read(
                fileName: url.lastPathComponent,
                as: DictationIPCResult.self,
                now: now,
                maxAge: resultMaxAge
            ), result.timestamp <= timestamp else { continue }
            _ = consume(
                fileName: url.lastPathComponent,
                as: DictationIPCResult.self,
                expectedSession: result.session,
                now: now,
                maxAge: resultMaxAge,
                session: { $0.session },
                timestamp: { $0.timestamp }
            )
        }
    }

    // MARK: 设置（键盘 -> 主 App）

    @discardableResult
    static func writeDictationSettings(_ settings: DictationSettings) -> Bool {
        write(settings, fileName: settingsFileName)
    }

    /// 后台尝试已消费设置后，失败时只能在没有更新会话的情况下回写。
    /// 比较和写入位于同一次文件协调中，避免“先检查 B、再被 A 覆盖”的竞态。
    static func requeueDictationSettingsIfNotSuperseded(
        _ settings: DictationSettings,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        guard let url = fileURL(named: settingsFileName),
              let data = try? JSONEncoder().encode(settings) else { return false }

        ioLock.lock()
        defer { ioLock.unlock() }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: Error?
        var didRequeue = false
        coordinator.coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            if let existingData = try? Data(contentsOf: coordinatedURL),
               let existing = try? JSONDecoder().decode(
                   DictationSettings.self,
                   from: existingData
               ), isFresh(existing.timestamp, now: now, maxAge: settingsMaxAge),
               existing.session != settings.session {
                return
            }
            do {
                try data.write(
                    to: coordinatedURL,
                    options: [.atomic, .completeFileProtection]
                )
                didRequeue = true
            } catch {
                operationError = error
            }
        }
        if let error = coordinationError {
            print("[DarwinBridge] IPC requeue failed: \(error.localizedDescription)")
            return false
        }
        if let operationError {
            print("[DarwinBridge] IPC requeue failed: \(operationError.localizedDescription)")
            return false
        }
        return didRequeue
    }

    /// 查看尚未处理的听写请求。主 App 被用户手动打开时可据此进入 DictationView。
    static func peekPendingDictationSettings(
        now: TimeInterval = Date().timeIntervalSince1970,
        maxAge: TimeInterval = settingsMaxAge
    ) -> DictationSettings? {
        read(fileName: settingsFileName, as: DictationSettings.self, now: now, maxAge: maxAge)
    }

    static func readAndConsumeDictationSettings(
        expectedSession: String? = nil,
        now: TimeInterval = Date().timeIntervalSince1970,
        maxAge: TimeInterval = settingsMaxAge
    ) -> DictationSettings? {
        consume(
            fileName: settingsFileName,
            as: DictationSettings.self,
            expectedSession: expectedSession,
            now: now,
            maxAge: maxAge,
            session: { $0.session },
            timestamp: { $0.timestamp }
        )
    }

    @discardableResult
    static func discardPendingDictationSettings(expectedSession: String) -> Bool {
        readAndConsumeDictationSettings(expectedSession: expectedSession) != nil
    }

    // MARK: 心跳与通知

    static func writeHeartbeat() {
        DarwinNotificationObserver.post(DarwinNotificationName.heartbeat)
    }

    static func isMainAppAlive(threshold: TimeInterval = 3.0) -> Bool {
        HeartbeatTracker.shared.isMainAppAlive(threshold: threshold)
    }

    static func heartbeatAge() -> TimeInterval {
        HeartbeatTracker.shared.heartbeatAge()
    }

    static func postNotification(_ name: String) {
        DarwinNotificationObserver.post(name)
    }

    /// Darwin 通知本身不携带 payload。会改变会话状态的通知必须把 session
    /// 哈希编码到通知名中，避免旧会话的迟到通知驱动当前会话。
    static func sessionNotificationName(base: String, session: String) -> String? {
        guard let token = sessionToken(session) else { return nil }
        return "\(base).\(token)"
    }

    @discardableResult
    static func postSessionNotification(base: String, session: String) -> Bool {
        guard let name = sessionNotificationName(base: base, session: session) else {
            return false
        }
        DarwinNotificationObserver.post(name)
        return true
    }

    // MARK: 文件协调

    private static func containerDirectory() -> URL? {
        configurationLock.lock()
        let isInjected = hasInjectedContainerDirectory
        let injected = injectedContainerDirectory
        configurationLock.unlock()
        if isInjected { return injected }
        return FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
    }

    private static func fileURL(named fileName: String) -> URL? {
        guard let directory = containerDirectory() else {
            print("[DarwinBridge] App Group container unavailable: \(appGroupIdentifier)")
            return nil
        }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            return directory.appendingPathComponent(fileName, isDirectory: false)
        } catch {
            print("[DarwinBridge] Cannot prepare IPC directory: \(error.localizedDescription)")
            return nil
        }
    }

    private static func resultFileName(for session: String) -> String? {
        guard let token = sessionToken(session) else { return nil }
        return "\(resultFilePrefix)\(token)\(resultFileSuffix)"
    }

    private static func resultFileURLs(in directory: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter {
            let name = $0.lastPathComponent
            return name.hasPrefix(resultFilePrefix) && name.hasSuffix(resultFileSuffix)
        }
    }

    private static func sessionToken(_ session: String) -> String? {
        let bytes = Data(session.utf8)
        guard !bytes.isEmpty, bytes.count <= 512 else { return nil }
        return SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func write<Value: Encodable>(_ value: Value, fileName: String) -> Bool {
        guard let url = fileURL(named: fileName),
              let data = try? JSONEncoder().encode(value) else { return false }

        ioLock.lock()
        defer { ioLock.unlock() }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: Error?
        coordinator.coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: [.atomic, .completeFileProtection])
            } catch {
                operationError = error
            }
        }

        if let error = coordinationError {
            print("[DarwinBridge] IPC write failed: \(error.localizedDescription)")
            return false
        }
        if let operationError {
            print("[DarwinBridge] IPC write failed: \(operationError.localizedDescription)")
            return false
        }
        return true
    }

    private static func read<Value: Decodable & TimestampedIPCValue>(
        fileName: String,
        as type: Value.Type,
        now: TimeInterval,
        maxAge: TimeInterval
    ) -> Value? {
        guard let url = fileURL(named: fileName) else { return nil }

        ioLock.lock()
        defer { ioLock.unlock() }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var value: Value?
        coordinator.coordinate(
            writingItemAt: url,
            options: .forMerging,
            error: &coordinationError
        ) { coordinatedURL in
            guard let data = try? Data(contentsOf: coordinatedURL),
                  let decoded = try? JSONDecoder().decode(Value.self, from: data) else {
                try? FileManager.default.removeItem(at: coordinatedURL)
                return
            }
            guard isFresh(decoded.timestamp, now: now, maxAge: maxAge) else {
                try? FileManager.default.removeItem(at: coordinatedURL)
                return
            }
            value = decoded
        }
        return coordinationError == nil ? value : nil
    }

    private static func consume<Value: Codable>(
        fileName: String,
        as type: Value.Type,
        expectedSession: String?,
        now: TimeInterval,
        maxAge: TimeInterval,
        session: (Value) -> String,
        timestamp: (Value) -> TimeInterval
    ) -> Value? {
        guard let url = fileURL(named: fileName) else { return nil }

        ioLock.lock()
        defer { ioLock.unlock() }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var consumed: Value?
        coordinator.coordinate(
            writingItemAt: url,
            options: .forMerging,
            error: &coordinationError
        ) { coordinatedURL in
            guard let data = try? Data(contentsOf: coordinatedURL),
                  let decoded = try? JSONDecoder().decode(Value.self, from: data) else {
                try? FileManager.default.removeItem(at: coordinatedURL)
                return
            }
            guard isFresh(timestamp(decoded), now: now, maxAge: maxAge) else {
                try? FileManager.default.removeItem(at: coordinatedURL)
                return
            }
            if let expectedSession, session(decoded) != expectedSession {
                return
            }
            do {
                try FileManager.default.removeItem(at: coordinatedURL)
                consumed = decoded
            } catch {
                print("[DarwinBridge] IPC consume failed: \(error.localizedDescription)")
            }
        }
        return coordinationError == nil ? consumed : nil
    }

    private static func isFresh(
        _ timestamp: TimeInterval,
        now: TimeInterval,
        maxAge: TimeInterval
    ) -> Bool {
        timestamp > 0 && timestamp <= now + 5 && now - timestamp <= maxAge
    }
}
