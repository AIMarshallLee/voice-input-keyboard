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
    static let liveStateChanged = "com.daseanle.votype.liveStateChanged"
    static let heartbeat = "com.daseanle.votype.heartbeat"
    static let readinessChanged = "com.daseanle.votype.readinessChanged"
}

/// Darwin 通知只负责发送“有新状态”的信号，业务数据全部放在 App Group 文件中。
final class DarwinNotificationObserver {
    private let name: String
    private let token: UInt

    private enum CallbackRegistry {
        static let lock = NSLock()
        static var nextToken: UInt = 1
        static var callbacks: [UInt: () -> Void] = [:]

        static func register(_ callback: @escaping () -> Void) -> UInt {
            lock.lock()
            defer { lock.unlock() }
            let token = nextToken
            nextToken &+= 1
            if nextToken == 0 { nextToken = 1 }
            callbacks[token] = callback
            return token
        }

        static func unregister(_ token: UInt) {
            lock.lock()
            callbacks.removeValue(forKey: token)
            lock.unlock()
        }

        static func invoke(_ token: UInt) {
            lock.lock()
            let callback = callbacks[token]
            lock.unlock()
            callback?()
        }
    }

    init(name: String, callback: @escaping () -> Void) {
        self.name = name
        token = CallbackRegistry.register(callback)

        // CF 不会解引用 observer context。使用永不复用的整数 token，而不是
        // Swift 对象裸指针，避免移除观察者与在途通知并发时访问已释放对象。
        let observerPointer = UnsafeMutableRawPointer(bitPattern: token)
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observerPointer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let token = UInt(bitPattern: observer)
                if Thread.isMainThread {
                    CallbackRegistry.invoke(token)
                } else {
                    DispatchQueue.main.async {
                        CallbackRegistry.invoke(token)
                    }
                }
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CallbackRegistry.unregister(token)
        if let observer = UnsafeMutableRawPointer(bitPattern: token) {
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

/// 主 App 在一个听写会话内持续发布的轻量快照。业务文字只存在 App Group
/// 文件中；Darwin 通知和文件名都只使用 session 的不可逆哈希。
enum DictationLivePhase: String, Codable, Equatable {
    case starting
    case listening
    case processing
}

struct DictationLiveState: Codable, Equatable {
    let session: String
    let phase: DictationLivePhase
    let partialTranscript: String
    let timestamp: TimeInterval
}

/// 宿主当前能否在不切换 App 的情况下承接键盘请求。
///
/// 这是带过期时间的事实快照，不是一个永久开关。键盘扩展即使在最近一次
/// Darwin 心跳之后才启动，也能从 App Group 文件得到可靠的冷/热路径判断。
struct DictationReadiness: Codable, Equatable {
    enum Mode: String, Codable, Equatable {
        case standby
        case recording
        case processing
    }

    let mode: Mode
    let timestamp: TimeInterval
}

private struct DictationCancellation: Codable {
    let session: String
    let timestamp: TimeInterval
}

/// 终态 payload 会被键盘消费并删除；receipt 独立保留，确保同一 session 的
/// 迟到回调在消费之后也不能再创建第二个终态。
private struct DictationTerminalReceipt: Codable {
    let session: String
    let timestamp: TimeInterval
}

/// 将高频 Speech partial 合并为最多约 5 次/秒的 App Group 写入。
/// 阶段切换使用 `publishImmediately`，不会被节流；终态前调用
/// `cancelPending`，避免排队中的 listening 快照在 clear 后重新出现。
@MainActor
final class DictationLiveStatePublisher {
    private let minimumPartialInterval: TimeInterval
    private var activeSession: String?
    private var lastPublishedPhase: DictationLivePhase?
    private var lastPublishedTranscript = ""
    private var lastPublishUptime: TimeInterval = 0
    private var pendingTranscript: String?
    private var pendingWorkItem: DispatchWorkItem?

    init(minimumPartialInterval: TimeInterval = 0.2) {
        self.minimumPartialInterval = min(0.25, max(0.15, minimumPartialInterval))
    }

    @discardableResult
    func publishImmediately(
        phase: DictationLivePhase,
        partialTranscript: String = "",
        session: String
    ) -> Bool {
        prepareSession(session)
        cancelScheduledPartial()
        return publishNow(
            phase: phase,
            partialTranscript: partialTranscript,
            session: session
        )
    }

    /// 合并相同文字，并让尚未到节流窗口的更新只保留最新一份。
    func publishPartial(_ partialTranscript: String, session: String) {
        guard DictationConstants.isValidSession(session) else { return }
        prepareSession(session)

        if let pendingTranscript {
            if pendingTranscript == partialTranscript { return }
            if lastPublishedPhase == .listening,
               lastPublishedTranscript == partialTranscript {
                // 最新回调回退到了已经发布的文字，撤销尚未落盘的中间版本。
                cancelScheduledPartial()
                return
            }
            self.pendingTranscript = partialTranscript
            return
        }
        if lastPublishedPhase == .listening,
           lastPublishedTranscript == partialTranscript {
            return
        }

        pendingTranscript = partialTranscript
        guard pendingWorkItem == nil else { return }

        let elapsed = ProcessInfo.processInfo.systemUptime - lastPublishUptime
        let delay = max(0, minimumPartialInterval - elapsed)
        if delay == 0 {
            flushPartial(session: session)
            return
        }

        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.flushPartial(session: session)
            }
        }
        pendingWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancelPending(for session: String? = nil) {
        if let session, activeSession != session { return }
        cancelScheduledPartial()
        activeSession = nil
        lastPublishedPhase = nil
        lastPublishedTranscript = ""
        lastPublishUptime = 0
    }

    private func prepareSession(_ session: String) {
        guard activeSession != session else { return }
        cancelScheduledPartial()
        activeSession = session
        lastPublishedPhase = nil
        lastPublishedTranscript = ""
        lastPublishUptime = 0
    }

    private func cancelScheduledPartial() {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        pendingTranscript = nil
    }

    private func flushPartial(session: String) {
        pendingWorkItem = nil
        guard activeSession == session,
              let transcript = pendingTranscript else { return }
        pendingTranscript = nil
        _ = publishNow(
            phase: .listening,
            partialTranscript: transcript,
            session: session
        )
    }

    private func publishNow(
        phase: DictationLivePhase,
        partialTranscript: String,
        session: String
    ) -> Bool {
        let didWrite = DarwinBridge.writeLiveState(
            phase: phase,
            partialTranscript: partialTranscript,
            session: session
        )
        if didWrite {
            lastPublishedPhase = phase
            lastPublishedTranscript = partialTranscript
            lastPublishUptime = ProcessInfo.processInfo.systemUptime
        }
        return didWrite
    }
}

private protocol TimestampedIPCValue {
    var timestamp: TimeInterval { get }
}

extension DictationSettings: TimestampedIPCValue {}
extension DictationIPCResult: TimestampedIPCValue {}
extension DictationLiveState: TimestampedIPCValue {}
extension DictationReadiness: TimestampedIPCValue {}
extension DictationCancellation: TimestampedIPCValue {}
extension DictationTerminalReceipt: TimestampedIPCValue {}

/// App Group 原子文件 IPC。Darwin 通知只传信号，文件承载带 session 的数据。
struct DarwinBridge {
    static let appGroupIdentifier = SharedDefaults.suiteName
    static let settingsMaxAge: TimeInterval = 60
    static let resultMaxAge: TimeInterval = 5 * 60
    static let liveStateMaxAge: TimeInterval = 2 * 60
    static let cancellationMaxAge: TimeInterval = 24 * 60 * 60
    static let terminalReceiptMaxAge: TimeInterval = 24 * 60 * 60
    static let readinessMaxAge: TimeInterval = 3.5

    private static let legacySettingsFileName = "dictation-settings.json"
    private static let settingsFilePrefix = "dictation-settings-"
    private static let settingsFileSuffix = ".json"
    private static let resultFilePrefix = "dictation-result-"
    private static let resultFileSuffix = ".json"
    private static let liveStateFilePrefix = "dictation-live-"
    private static let liveStateFileSuffix = ".json"
    private static let cancellationFilePrefix = "dictation-cancel-"
    private static let cancellationFileSuffix = ".json"
    private static let terminalReceiptFilePrefix = "dictation-terminal-"
    private static let terminalReceiptFileSuffix = ".json"
    private static let sessionLockFilePrefix = "dictation-session-"
    private static let sessionLockFileSuffix = ".lock"
    private static let readinessFileName = "dictation-readiness.json"
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
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(legacySettingsFileName)
        )
        for url in settingsFileURLs(in: directory) {
            try? FileManager.default.removeItem(at: url)
        }
        for url in resultFileURLs(in: directory) {
            try? FileManager.default.removeItem(at: url)
        }
        for url in liveStateFileURLs(in: directory) {
            try? FileManager.default.removeItem(at: url)
        }
        for url in cancellationFileURLs(in: directory) {
            try? FileManager.default.removeItem(at: url)
        }
        for url in terminalReceiptFileURLs(in: directory) {
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(readinessFileName)
        )
    }

    // MARK: 结果（主 App -> 键盘）

    @discardableResult
    static func writeTranscription(
        _ text: String,
        session: String,
        deleteSelected: Bool = false,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        let payload = DictationIPCResult(
            status: .completed,
            text: text,
            session: session,
            deleteSelected: deleteSelected,
            timestamp: timestamp
        )
        let outcome = writeTerminalResult(payload)
        guard outcome == .written else { return false }
        DarwinNotificationObserver.post(DarwinNotificationName.transcriptionReady)
        return true
    }

    @discardableResult
    static func writeError(
        _ message: String,
        session: String,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        let payload = DictationIPCResult(
            status: .error,
            text: message,
            session: session,
            deleteSelected: false,
            timestamp: timestamp
        )
        let outcome = writeTerminalResult(payload)
        guard outcome == .written else { return false }
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
                guard let result = read(
                    fileName: url.lastPathComponent,
                    as: DictationIPCResult.self,
                    now: now,
                    maxAge: maxAge
                ) else { return nil }
                if isSessionCancelled(session: result.session, now: now) {
                    discardResult(session: result.session)
                    return nil
                }
                return result
            }
            .max(by: { $0.timestamp < $1.timestamp })
    }

    /// 只查看指定 session 的结果，不会被其他并发会话的更新时间遮挡。
    static func peekResult(
        expectedSession: String,
        now: TimeInterval = Date().timeIntervalSince1970,
        maxAge: TimeInterval = resultMaxAge
    ) -> DictationIPCResult? {
        guard let resultName = resultFileName(for: expectedSession) else { return nil }
        return withSessionLock(session: expectedSession, defaultValue: nil) { directory in
            let resultURL = directory.appendingPathComponent(resultName)
            if isCancelledUncoordinated(session: expectedSession, in: directory, now: now) {
                removeUncoordinated(resultURL)
                return nil
            }
            guard let result: DictationIPCResult = readUncoordinated(
                from: resultURL,
                now: now,
                maxAge: maxAge
            ), result.session == expectedSession else { return nil }
            return result
        }
    }

    /// 仅 session 匹配时原子消费；不匹配时文件保持不变。
    static func readAndConsumeResult(
        expectedSession: String,
        now: TimeInterval = Date().timeIntervalSince1970,
        maxAge: TimeInterval = resultMaxAge
    ) -> DictationIPCResult? {
        guard let resultName = resultFileName(for: expectedSession) else { return nil }
        return withSessionLock(session: expectedSession, defaultValue: nil) { directory in
            let resultURL = directory.appendingPathComponent(resultName)
            if isCancelledUncoordinated(session: expectedSession, in: directory, now: now) {
                removeUncoordinated(resultURL)
                return nil
            }
            guard let result: DictationIPCResult = readUncoordinated(
                from: resultURL,
                now: now,
                maxAge: maxAge
            ), result.session == expectedSession else { return nil }
            guard ensureTerminalReceiptUncoordinated(
                for: result,
                in: directory,
                now: now
            ) else { return nil }
            guard removeUncoordinated(resultURL) else { return nil }
            return result
        }
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
            _ = readAndConsumeResult(
                expectedSession: result.session,
                now: now,
                maxAge: resultMaxAge
            )
        }
    }

    // MARK: 实时状态（主 App -> 键盘）

    /// 原子发布一个会话的最新实时快照。较旧时间戳的迟到回调不能覆盖更新快照。
    /// 每次成功写入只发送 session-scoped 信号，通知本身不携带识别文字。
    @discardableResult
    static func writeLiveState(
        phase: DictationLivePhase,
        partialTranscript: String = "",
        session: String,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        guard DictationConstants.isValidSession(session),
              timestamp > 0,
              let fileName = liveStateFileName(for: session) else { return false }
        let state = DictationLiveState(
            session: session,
            phase: phase,
            partialTranscript: partialTranscript,
            timestamp: timestamp
        )
        let didWrite = withSessionLock(session: session, defaultValue: false) { directory in
            guard !isCancelledUncoordinated(session: session, in: directory),
                  !hasFreshTerminalUncoordinated(session: session, in: directory) else {
                return false
            }
            let url = directory.appendingPathComponent(fileName)
            if let existing: DictationLiveState = readUncoordinated(
                from: url,
                now: timestamp,
                maxAge: liveStateMaxAge
            ) {
                guard existing.session == state.session,
                      existing.timestamp <= state.timestamp else { return false }
                if livePhaseRank(existing.phase) > livePhaseRank(state.phase) {
                    return false
                }
            }
            return writeUncoordinated(state, to: url)
        }
        guard didWrite else { return false }
        postSessionNotification(
            base: DarwinNotificationName.liveStateChanged,
            session: session
        )
        return true
    }

    /// 非消费式读取指定会话的最新快照。会话不匹配、损坏或过期都不会返回文字。
    static func readLiveState(
        expectedSession: String,
        now: TimeInterval = Date().timeIntervalSince1970,
        maxAge: TimeInterval = liveStateMaxAge
    ) -> DictationLiveState? {
        guard DictationConstants.isValidSession(expectedSession),
              let fileName = liveStateFileName(for: expectedSession) else { return nil }
        return withSessionLock(session: expectedSession, defaultValue: nil) { directory in
            if isCancelledUncoordinated(session: expectedSession, in: directory, now: now)
                || hasFreshTerminalUncoordinated(
                    session: expectedSession,
                    in: directory,
                    now: now
                ) {
                removeUncoordinated(directory.appendingPathComponent(fileName))
                return nil
            }
            guard let state: DictationLiveState = readUncoordinated(
                from: directory.appendingPathComponent(fileName),
                now: now,
                maxAge: maxAge
            ), state.session == expectedSession else { return nil }
            return state
        }
    }

    /// 终态、取消或会话被替代后清理快照。即使文件已经不存在也发送变更
    /// 通知，使键盘可以立即隐藏原地反馈，而不必等待 TTL。
    @discardableResult
    static func clearLiveState(session: String) -> Bool {
        guard DictationConstants.isValidSession(session),
              let fileName = liveStateFileName(for: session) else { return false }
        let didClear = withSessionLock(session: session, defaultValue: false) { directory in
            removeUncoordinated(directory.appendingPathComponent(fileName))
        }
        if didClear {
            postSessionNotification(
                base: DarwinNotificationName.liveStateChanged,
                session: session
            )
        }
        return didClear
    }

    // MARK: 取消墓碑（键盘 -> 主 App）

    /// 用户超时或主动取消后先落盘墓碑，再通知宿主停止。宿主所有迟到的
    /// Speech/文字处理回调都会被结果写入 API 拒绝，避免数分钟后误插入。
    @discardableResult
    static func cancelSession(
        _ session: String,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        guard DictationConstants.isValidSession(session),
              timestamp > 0,
              let cancellationName = cancellationFileName(for: session),
              let resultName = resultFileName(for: session),
              let liveName = liveStateFileName(for: session),
              let settingsName = settingsFileName(for: session) else { return false }
        let marker = DictationCancellation(session: session, timestamp: timestamp)
        let didWrite = withSessionLock(session: session, defaultValue: false) { directory in
            guard writeUncoordinated(
                marker,
                to: directory.appendingPathComponent(cancellationName)
            ) else { return false }
            removeUncoordinated(directory.appendingPathComponent(resultName))
            removeUncoordinated(directory.appendingPathComponent(liveName))
            removeUncoordinated(directory.appendingPathComponent(settingsName))
            return true
        }
        if didWrite {
            postSessionNotification(
                base: DarwinNotificationName.liveStateChanged,
                session: session
            )
        }
        return didWrite
    }

    static func isSessionCancelled(
        session: String,
        now: TimeInterval = Date().timeIntervalSince1970,
        maxAge: TimeInterval = cancellationMaxAge
    ) -> Bool {
        guard DictationConstants.isValidSession(session) else { return false }
        return withSessionLock(session: session, defaultValue: false) { directory in
            isCancelledUncoordinated(
                session: session,
                in: directory,
                now: now,
                maxAge: maxAge
            )
        }
    }

    // MARK: 设置（键盘 -> 主 App）

    @discardableResult
    static func writeDictationSettings(_ settings: DictationSettings) -> Bool {
        garbageCollectExpiredCancellations()
        garbageCollectExpiredTerminalReceipts()
        guard let fileName = settingsFileName(for: settings.session) else { return false }
        return withSessionLock(session: settings.session, defaultValue: false) { directory in
            guard !isCancelledUncoordinated(session: settings.session, in: directory) else {
                return false
            }
            let url = directory.appendingPathComponent(fileName)
            if let existing: DictationSettings = readUncoordinated(
                from: url,
                now: Date().timeIntervalSince1970,
                maxAge: settingsMaxAge
            ), existing.timestamp > settings.timestamp {
                return false
            }
            return writeUncoordinated(settings, to: url)
        }
    }

    /// 后台尝试已消费设置后，失败时只能在没有更新会话的情况下回写。
    /// 比较和写入位于同一次文件协调中，避免“先检查 B、再被 A 覆盖”的竞态。
    static func requeueDictationSettingsIfNotSuperseded(
        _ settings: DictationSettings,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        guard let fileName = settingsFileName(for: settings.session) else { return false }
        return withSessionLock(session: settings.session, defaultValue: false) { directory in
            guard !isCancelledUncoordinated(
                session: settings.session,
                in: directory,
                now: now
            ) else { return false }

            // 若已有更新会话，旧失败会话不得重新进入队列。跨进程写采用
            // 原子文件；即使更新请求在扫描后到达，peek 仍会按 timestamp
            // 选择它，且消费时会清掉更旧请求。
            for url in settingsFileURLs(in: directory)
                where url.lastPathComponent != fileName {
                if let newer: DictationSettings = readUncoordinated(
                    from: url,
                    now: now,
                    maxAge: settingsMaxAge
                ), newer.timestamp > settings.timestamp {
                    return false
                }
            }
            return writeUncoordinated(
                settings,
                to: directory.appendingPathComponent(fileName)
            )
        }
    }

    /// 查看尚未处理的听写请求。主 App 被用户手动打开时可据此进入 DictationView。
    static func peekPendingDictationSettings(
        now: TimeInterval = Date().timeIntervalSince1970,
        maxAge: TimeInterval = settingsMaxAge
    ) -> DictationSettings? {
        guard let directory = containerDirectory() else { return nil }
        return settingsFileURLs(in: directory)
            .compactMap { url in
                guard let settings = read(
                    fileName: url.lastPathComponent,
                    as: DictationSettings.self,
                    now: now,
                    maxAge: maxAge
                ) else { return nil }
                if isSessionCancelled(session: settings.session, now: now) {
                    _ = discardPendingDictationSettings(expectedSession: settings.session)
                    return nil
                }
                return settings
            }
            .max(by: { $0.timestamp < $1.timestamp })
    }

    static func readAndConsumeDictationSettings(
        expectedSession: String? = nil,
        now: TimeInterval = Date().timeIntervalSince1970,
        maxAge: TimeInterval = settingsMaxAge
    ) -> DictationSettings? {
        guard let session = expectedSession ?? peekPendingDictationSettings(
            now: now,
            maxAge: maxAge
        )?.session,
              let fileName = settingsFileName(for: session) else { return nil }
        let consumed: DictationSettings? = withSessionLock(
            session: session,
            defaultValue: nil
        ) { directory in
            let url = directory.appendingPathComponent(fileName)
            if isCancelledUncoordinated(session: session, in: directory, now: now) {
                removeUncoordinated(url)
                return nil
            }
            guard let settings: DictationSettings = readUncoordinated(
                from: url,
                now: now,
                maxAge: maxAge
            ), settings.session == session else { return nil }
            guard removeUncoordinated(url) else { return nil }
            return settings
        }
        if let consumed {
            discardOlderPendingSettings(
                through: consumed.timestamp,
                excluding: consumed.session,
                now: now,
                maxAge: maxAge
            )
        }
        return consumed
    }

    @discardableResult
    static func discardPendingDictationSettings(expectedSession: String) -> Bool {
        readAndConsumeDictationSettings(expectedSession: expectedSession) != nil
    }

    private static func discardOlderPendingSettings(
        through timestamp: TimeInterval,
        excluding session: String,
        now: TimeInterval,
        maxAge: TimeInterval
    ) {
        guard let directory = containerDirectory() else { return }
        for url in settingsFileURLs(in: directory) {
            guard let candidate = read(
                fileName: url.lastPathComponent,
                as: DictationSettings.self,
                now: now,
                maxAge: maxAge
            ), candidate.session != session,
               candidate.timestamp <= timestamp else { continue }
            _ = withSessionLock(session: candidate.session, defaultValue: false) { directory in
                guard let fileName = settingsFileName(for: candidate.session),
                      let current: DictationSettings = readUncoordinated(
                        from: directory.appendingPathComponent(fileName),
                        now: now,
                        maxAge: maxAge
                      ), current.session == candidate.session,
                         current.timestamp <= timestamp else { return false }
                return removeUncoordinated(
                    directory.appendingPathComponent(fileName)
                )
            }
        }
    }

    // MARK: 心跳与通知

    /// 发布宿主的短期可用状态。只有画中画待命实际处于 active，或一个录音
    /// 会话正在运行时才应调用；快照停止刷新后会自动过期为冷启动路径。
    @discardableResult
    static func writeReadiness(
        _ mode: DictationReadiness.Mode,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        guard timestamp > 0,
              let url = fileURL(named: readinessFileName) else { return false }
        let value = DictationReadiness(mode: mode, timestamp: timestamp)

        ioLock.lock()
        defer { ioLock.unlock() }
        let didWrite = writeUncoordinated(value, to: url)
        if didWrite {
            DarwinNotificationObserver.post(DarwinNotificationName.readinessChanged)
            DarwinNotificationObserver.post(DarwinNotificationName.heartbeat)
        }
        return didWrite
    }

    static func readReadiness(
        now: TimeInterval = Date().timeIntervalSince1970,
        maxAge: TimeInterval = readinessMaxAge
    ) -> DictationReadiness? {
        read(
            fileName: readinessFileName,
            as: DictationReadiness.self,
            now: now,
            maxAge: maxAge
        )
    }

    /// 只有 standby 能接收一个全新会话；recording/processing 用于界面状态，
    /// 不能被另一个输入框误判为可立即开麦。
    static func canStartInPlace(
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        readReadiness(now: now)?.mode == .standby
    }

    @discardableResult
    static func clearReadiness() -> Bool {
        guard let url = fileURL(named: readinessFileName) else { return false }
        ioLock.lock()
        let removed = removeUncoordinated(url)
        ioLock.unlock()
        if removed {
            DarwinNotificationObserver.post(DarwinNotificationName.readinessChanged)
        }
        return removed
    }

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

    private static func settingsFileName(for session: String) -> String? {
        guard let token = sessionToken(session) else { return nil }
        return "\(settingsFilePrefix)\(token)\(settingsFileSuffix)"
    }

    private static func liveStateFileName(for session: String) -> String? {
        guard let token = sessionToken(session) else { return nil }
        return "\(liveStateFilePrefix)\(token)\(liveStateFileSuffix)"
    }

    private static func cancellationFileName(for session: String) -> String? {
        guard let token = sessionToken(session) else { return nil }
        return "\(cancellationFilePrefix)\(token)\(cancellationFileSuffix)"
    }

    private static func terminalReceiptFileName(for session: String) -> String? {
        guard let token = sessionToken(session) else { return nil }
        return "\(terminalReceiptFilePrefix)\(token)\(terminalReceiptFileSuffix)"
    }

    private static func sessionLockFileName(for session: String) -> String? {
        guard let token = sessionToken(session) else { return nil }
        return "\(sessionLockFilePrefix)\(token)\(sessionLockFileSuffix)"
    }

    private static func settingsFileURLs(in directory: URL) -> [URL] {
        matchingFileURLs(
            in: directory,
            prefix: settingsFilePrefix,
            suffix: settingsFileSuffix
        )
    }

    private static func resultFileURLs(in directory: URL) -> [URL] {
        matchingFileURLs(
            in: directory,
            prefix: resultFilePrefix,
            suffix: resultFileSuffix
        )
    }

    private static func liveStateFileURLs(in directory: URL) -> [URL] {
        matchingFileURLs(
            in: directory,
            prefix: liveStateFilePrefix,
            suffix: liveStateFileSuffix
        )
    }

    private static func cancellationFileURLs(in directory: URL) -> [URL] {
        matchingFileURLs(
            in: directory,
            prefix: cancellationFilePrefix,
            suffix: cancellationFileSuffix
        )
    }

    private static func terminalReceiptFileURLs(in directory: URL) -> [URL] {
        matchingFileURLs(
            in: directory,
            prefix: terminalReceiptFilePrefix,
            suffix: terminalReceiptFileSuffix
        )
    }

    private static func matchingFileURLs(
        in directory: URL,
        prefix: String,
        suffix: String
    ) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter {
            let name = $0.lastPathComponent
            return name.hasPrefix(prefix) && name.hasSuffix(suffix)
        }
    }

    private static func garbageCollectExpiredCancellations(
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        guard let directory = containerDirectory() else { return }
        for url in cancellationFileURLs(in: directory) {
            _ = read(
                fileName: url.lastPathComponent,
                as: DictationCancellation.self,
                now: now,
                maxAge: cancellationMaxAge
            )
        }
    }

    private static func garbageCollectExpiredTerminalReceipts(
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        guard let directory = containerDirectory() else { return }
        for url in terminalReceiptFileURLs(in: directory) {
            guard let data = try? Data(contentsOf: url),
                  let receipt = try? JSONDecoder().decode(
                    DictationTerminalReceipt.self,
                    from: data
                  ),
                  terminalReceiptFileName(for: receipt.session) == url.lastPathComponent else {
                continue
            }
            _ = withSessionLock(session: receipt.session, defaultValue: false) { directory in
                let receiptURL = directory.appendingPathComponent(url.lastPathComponent)
                guard let currentData = try? Data(contentsOf: receiptURL),
                      let current = try? JSONDecoder().decode(
                        DictationTerminalReceipt.self,
                        from: currentData
                      ),
                      current.session == receipt.session,
                      !isFresh(
                        current.timestamp,
                        now: now,
                        maxAge: terminalReceiptMaxAge
                      ) else { return false }
                return removeUncoordinated(receiptURL)
            }
        }
    }

    private static func sessionToken(_ session: String) -> String? {
        let bytes = Data(session.utf8)
        guard !bytes.isEmpty, bytes.count <= 512 else { return nil }
        return SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private enum TerminalWriteOutcome: Equatable {
        case written
        case alreadyTerminal
        case cancelled
        case ioFailure
    }

    /// 所有会改变同一 session 的设置、实时状态、终态或取消状态的操作，
    /// 都先协调同一个虚拟 lock URL。这样 App 与扩展两个进程之间也能获得
    /// 明确的先后顺序，而不是只依赖各进程自己的 NSLock。
    private static func withSessionLock<Value>(
        session: String,
        defaultValue: Value,
        _ body: (URL) -> Value
    ) -> Value {
        guard let lockName = sessionLockFileName(for: session),
              let lockURL = fileURL(named: lockName) else { return defaultValue }

        ioLock.lock()
        defer { ioLock.unlock() }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var didRun = false
        var value = defaultValue
        coordinator.coordinate(
            writingItemAt: lockURL,
            options: .forMerging,
            error: &coordinationError
        ) { _ in
            value = body(lockURL.deletingLastPathComponent())
            didRun = true
        }
        if let coordinationError {
            print("[DarwinBridge] Session IPC coordination failed: \(coordinationError.localizedDescription)")
            return defaultValue
        }
        return didRun ? value : defaultValue
    }

    private static func writeTerminalResult(
        _ result: DictationIPCResult
    ) -> TerminalWriteOutcome {
        guard let resultName = resultFileName(for: result.session),
              let liveName = liveStateFileName(for: result.session),
              let receiptName = terminalReceiptFileName(for: result.session) else {
            return .ioFailure
        }
        return withSessionLock(session: result.session, defaultValue: .ioFailure) { directory in
            guard !isCancelledUncoordinated(session: result.session, in: directory) else {
                removeUncoordinated(directory.appendingPathComponent(resultName))
                removeUncoordinated(directory.appendingPathComponent(liveName))
                return .cancelled
            }

            let resultURL = directory.appendingPathComponent(resultName)
            let receiptURL = directory.appendingPathComponent(receiptName)
            if let receipt: DictationTerminalReceipt = readUncoordinated(
                from: receiptURL,
                now: Date().timeIntervalSince1970,
                maxAge: terminalReceiptMaxAge
            ), receipt.session == result.session {
                removeUncoordinated(directory.appendingPathComponent(liveName))
                return .alreadyTerminal
            }
            if let existing: DictationIPCResult = readUncoordinated(
                from: resultURL,
                now: Date().timeIntervalSince1970,
                maxAge: resultMaxAge
            ) {
                if existing.session == result.session {
                    // 第一个终态是权威结果。错误、超时或被替代回调不得覆盖它。
                    guard ensureTerminalReceiptUncoordinated(
                        for: existing,
                        in: directory
                    ) else { return .ioFailure }
                    removeUncoordinated(directory.appendingPathComponent(liveName))
                    return .alreadyTerminal
                }
                removeUncoordinated(resultURL)
            }
            guard writeUncoordinated(result, to: resultURL) else { return .ioFailure }
            let receipt = DictationTerminalReceipt(
                session: result.session,
                timestamp: Date().timeIntervalSince1970
            )
            guard writeUncoordinated(receipt, to: receiptURL) else {
                removeUncoordinated(resultURL)
                return .ioFailure
            }
            removeUncoordinated(directory.appendingPathComponent(liveName))
            return .written
        }
    }

    private static func ensureTerminalReceiptUncoordinated(
        for result: DictationIPCResult,
        in directory: URL,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        guard let receiptName = terminalReceiptFileName(for: result.session) else {
            return false
        }
        let receiptURL = directory.appendingPathComponent(receiptName)
        if let receipt: DictationTerminalReceipt = readUncoordinated(
            from: receiptURL,
            now: now,
            maxAge: terminalReceiptMaxAge
        ) {
            return receipt.session == result.session
        }
        return writeUncoordinated(
            DictationTerminalReceipt(session: result.session, timestamp: now),
            to: receiptURL
        )
    }

    private static func discardResult(session: String) {
        guard let resultName = resultFileName(for: session) else { return }
        _ = withSessionLock(session: session, defaultValue: false) { directory in
            removeUncoordinated(directory.appendingPathComponent(resultName))
        }
    }

    private static func isCancelledUncoordinated(
        session: String,
        in directory: URL,
        now: TimeInterval = Date().timeIntervalSince1970,
        maxAge: TimeInterval = cancellationMaxAge
    ) -> Bool {
        guard let fileName = cancellationFileName(for: session),
              let marker: DictationCancellation = readUncoordinated(
                from: directory.appendingPathComponent(fileName),
                now: now,
                maxAge: maxAge
              ) else { return false }
        return marker.session == session
    }

    private static func hasFreshTerminalUncoordinated(
        session: String,
        in directory: URL,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        if let receiptName = terminalReceiptFileName(for: session),
           let receipt: DictationTerminalReceipt = readUncoordinated(
                from: directory.appendingPathComponent(receiptName),
                now: now,
                maxAge: terminalReceiptMaxAge
           ), receipt.session == session {
            return true
        }
        guard let fileName = resultFileName(for: session),
              let result: DictationIPCResult = readUncoordinated(
                from: directory.appendingPathComponent(fileName),
                now: now,
                maxAge: resultMaxAge
              ) else { return false }
        return result.session == session
    }

    private static func livePhaseRank(_ phase: DictationLivePhase) -> Int {
        switch phase {
        case .starting: return 0
        case .listening: return 1
        case .processing: return 2
        }
    }

    @discardableResult
    private static func writeUncoordinated<Value: Encodable>(
        _ value: Value,
        to url: URL
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            print("[DarwinBridge] IPC write failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func readUncoordinated<Value: Decodable & TimestampedIPCValue>(
        from url: URL,
        now: TimeInterval,
        maxAge: TimeInterval
    ) -> Value? {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Value.self, from: data),
              isFresh(decoded.timestamp, now: now, maxAge: maxAge) else {
            removeUncoordinated(url)
            return nil
        }
        return decoded
    }

    @discardableResult
    private static func removeUncoordinated(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            print("[DarwinBridge] IPC delete failed: \(error.localizedDescription)")
            return false
        }
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

    private static func isFresh(
        _ timestamp: TimeInterval,
        now: TimeInterval,
        maxAge: TimeInterval
    ) -> Bool {
        timestamp > 0 && timestamp <= now + 5 && now - timestamp <= maxAge
    }
}
