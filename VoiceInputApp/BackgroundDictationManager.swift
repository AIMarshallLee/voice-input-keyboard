import Foundation
import AVFoundation
import Speech
import AVKit
import UIKit

/// 后台语音听写管理器 (Build 28)
///
/// 核心保活方案:
/// 1. 权限授权后自动激活后台音频会话 + 持续播放极低音量噪声
/// 2. iOS 认为 App 在"播放音频" → 不挂起 App → Darwin 通知永远能送达
/// 3. 不使用 PiP 悬浮窗（太显眼影响体验）
/// 4. 键盘点麦克风 → Darwin 通知 → 主 App 后台录音 → 结果回传
/// 5. 全程不切换 App
///
/// Build 28 修复:
/// - 移除 .duckOthers（iOS 对 duckOthers 的 session 更容易挂起）
/// - 统一 audio session 配置（录音和待命用相同 category+options）
/// - 添加音频中断恢复处理
/// - 提高静音播放器音量到 0.03
@MainActor
class BackgroundDictationManager: ObservableObject {

    static let shared = BackgroundDictationManager()

    // MARK: - 状态

    enum State {
        case idle           // 待命中
        case recording      // 正在录音
        case processing     // 正在处理结果
    }

    @Published private(set) var state: State = .idle
    @Published var isPipStandbyEnabled = false  // 后台保活是否开启

    private let pipStandbyKey = "pipStandbyEnabled"
    private let sharedDefaults = SharedDefaults.shared

    // MARK: - 录音相关

    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizedText = ""
    private var silenceTimer: DispatchSourceTimer?
    private var lastTextUpdateTime: CFAbsoluteTime = 0

    // 心跳定时器
    private var heartbeatTimer: DispatchSourceTimer?

    // 极低音量噪声播放器: 让 iOS 认为 App 在"播放音频"
    private let silentPlayer = SilentAudioPlayer()

    // Darwin 通知监听
    private var startDictationObserver: DarwinNotificationObserver?
    private var stopDictationObserver: DarwinNotificationObserver?

    // 当前会话
    private var currentSessionId = ""
    private var currentSettings: DictationSettings?
    private var sessionGeneration: UInt = 0

    // MARK: - 初始化

    private init() {
        setupDarwinObservers()
        setupAudioInterruptionHandling()
    }

    /// App 启动时调用:权限已授权就自动启用后台保活
    func autoRestoreIfNeeded() {
        guard sharedDefaults.bool(forKey: pipStandbyKey) else {
            isPipStandbyEnabled = false
            return
        }
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let micStatus = AVAudioSession.sharedInstance().recordPermission

        guard speechStatus == .authorized, micStatus == .granted else {
            print("[BGDictation] Permissions not granted yet, skipping auto-restore")
            return
        }

        if isPipStandbyEnabled { return }

        print("[BGDictation] Auto-enabling background standby (permissions granted)")
        enablePipStandby()
    }

    deinit {
        heartbeatTimer?.cancel()
    }

    // MARK: - 音频中断处理

    /// 监听音频中断（电话、Siri、其他 App 播放音频等）
    /// 中断结束后立即恢复 audio session + silent player
    private func setupAudioInterruptionHandling() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            guard let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

            switch type {
            case .began:
                print("[BGDictation] Audio interruption began")
            case .ended:
                print("[BGDictation] Audio interruption ended, recovering...")
                self.recoverFromInterruption()
            @unknown default:
                break
            }
        }

        // 监听音频路由变化（耳机插拔、蓝牙切换等）
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            guard let userInfo = notification.userInfo,
                  let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

            if reason == .oldDeviceUnavailable || reason == .newDeviceAvailable {
                print("[BGDictation] Audio route changed, recovering audio session")
                self.recoverFromInterruption()
            }
        }
    }

    /// 从音频中断中恢复
    private func recoverFromInterruption() {
        guard isPipStandbyEnabled else { return }

        // 录音中的 audio engine/route 已不可假定有效，不能启动噪声播放器污染输入。
        guard state != .recording else {
            cleanupForFallback()
            return
        }

        activateBackgroundAudioSession()
        silentPlayer.stop()
        silentPlayer.start()

        print("[BGDictation] Audio session recovered, silent player restarted")
    }

    // MARK: - Darwin 通知监听

    private func setupDarwinObservers() {
        startDictationObserver = DarwinNotificationObserver(
            name: DarwinNotificationName.requestStartDictation
        ) { [weak self] in
            Task { @MainActor in
                self?.handleDictationRequest()
            }
        }

    }

    private func observeStopRequest(for session: String) {
        guard let name = DarwinBridge.sessionNotificationName(
            base: DarwinNotificationName.requestStopDictation,
            session: session
        ) else {
            stopDictationObserver = nil
            return
        }
        stopDictationObserver = DarwinNotificationObserver(name: name) { [weak self] in
            Task { @MainActor in
                guard let self, self.currentSessionId == session else { return }
                self.stopRecording()
            }
        }
    }

    // MARK: - 后台保活模式

    /// 开启后台保活
    /// 不使用 PiP 悬浮窗（太显眼影响体验）
    /// 仅靠: UIBackgroundModes:audio + 极低音量噪声持续播放
    func enablePipStandby() {
        guard !isPipStandbyEnabled else { return }
        isPipStandbyEnabled = true

        sharedDefaults.set(true, forKey: pipStandbyKey)

        // 激活音频会话 + 开始播放极低音量噪声
        activateBackgroundAudioSession()
        silentPlayer.start()

        // 启动心跳
        startHeartbeat()

        print("[BGDictation] Background standby enabled (no PiP, audio-only keep-alive)")
    }

    /// 激活后台音频会话
    /// ★ 关键修复: 移除 .duckOthers！
    /// .duckOthers 会让 iOS 认为这个 session 是"次要"的，更容易被挂起
    /// 只用 .mixWithOthers + 蓝牙选项，iOS 认为是正常的后台音频播放
    private func activateBackgroundAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            print("[BGDictation] Background audio session activated (no duckOthers)")
        } catch {
            print("[BGDictation] Failed to activate audio session: \(error.localizedDescription)")
        }
    }

    /// 关闭后台保活
    func disablePipStandby() {
        isPipStandbyEnabled = false
        sharedDefaults.set(false, forKey: pipStandbyKey)
        stopHeartbeat()
        silentPlayer.stop()

        if state == .recording {
            stopRecording()
        }

        state = .idle

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

        print("[BGDictation] Background standby disabled")
    }

    /// 录音结束后只恢复用户明确开启过的待命模式。
    func resumeStandbyIfEnabled() {
        guard sharedDefaults.bool(forKey: pipStandbyKey) else {
            isPipStandbyEnabled = false
            silentPlayer.stop()
            return
        }
        if !isPipStandbyEnabled {
            enablePipStandby()
        } else {
            activateBackgroundAudioSession()
            silentPlayer.stop()
            silentPlayer.start()
            startHeartbeat()
        }
    }

    // MARK: - 心跳

    private func startHeartbeat() {
        stopHeartbeat()

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        timer.schedule(deadline: .now(), repeating: 2.0)
        timer.setEventHandler { DarwinBridge.writeHeartbeat() }
        timer.resume()
        heartbeatTimer = timer

        DarwinBridge.writeHeartbeat()
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    // MARK: - 处理听写请求

    private func handleDictationRequest() {
        // ★ Build 33: 尝试后台识别，失败则快速降级到前台
        // 1. 立即发 dictationStarted → 键盘不跳转
        // 2. 尝试后台 SFSpeechRecognizer
        // 3. 3s 内无结果 → 发 dictationFailed → 键盘降级 URL Scheme → 前台识别
        // 4. 识别成功 → 发 transcriptionReady → 不跳转！

        guard let pending = DarwinBridge.peekPendingDictationSettings() else {
            print("[BGDictation] No fresh settings request")
            return
        }

        if state != .idle {
            print("[BGDictation] New request supersedes the active session")
            cancelCurrentSessionForSupersedingRequest()
        }

        // 先查看 session，再只消费完全匹配且未过期的请求。
        guard let settings = DarwinBridge.readAndConsumeDictationSettings(
                expectedSession: pending.session
              ) else {
            print("[BGDictation] Pending settings changed before consume")
            return
        }

        currentSessionId = settings.session
        currentSettings = settings
        sessionGeneration &+= 1
        observeStopRequest(for: settings.session)

        // 只有成功取得会话后才确认开始，避免键盘取消 URL 降级却没有录音。
        DarwinBridge.postSessionNotification(
            base: DarwinNotificationName.dictationStarted,
            session: settings.session
        )
        print("[BGDictation] dictationStarted sent")

        print("[BGDictation] Starting background recognition, session=\(settings.session.prefix(8))")

        // 开始录音（内部会停止 SilentAudioPlayer）
        startRecording(settings: settings)

        // 3s 识别超时：如果 3s 内没有识别到任何文字，认为后台识别失败
        let requestSession = settings.session
        let requestGeneration = sessionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            guard self.state == .recording,
                  self.currentSessionId == requestSession,
                  self.sessionGeneration == requestGeneration,
                  self.recognizedText.isEmpty else { return }
            print("[BGDictation] 3s timeout - no recognition result, falling back to foreground")
            self.cleanupForFallback()
        }
    }

    /// 键盘扩展重建后可能在旧会话尚未完成时创建新会话。最新请求接管时，
    /// 使旧异步处理失效并释放音频资源；旧任务之后不得重配 audio session。
    private func cancelCurrentSessionForSupersedingRequest() {
        let supersededSession = currentSessionId
        sessionGeneration &+= 1
        silenceTimer?.cancel()
        silenceTimer = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        cleanupAudio()

        state = .idle
        currentSettings = nil
        currentSessionId = ""
        recognizedText = ""
        stopDictationObserver = nil
        silentPlayer.stop()
        if !supersededSession.isEmpty {
            DarwinBridge.writeError(
                "语音会话已被新的请求替代",
                session: supersededSession
            )
        }
        DarwinBridge.postNotification(DarwinNotificationName.dictationStopped)
    }

    /// 后台识别失败时清理并发送 dictationFailed
    /// 键盘收到后立即降级到 URL Scheme → 前台 DictationView 识别
    private func cleanupForFallback() {
        print("[BGDictation] Cleaning up for foreground fallback")

        // Path A 已经消费了设置。先把同一会话刷新后写回 App Group，确保
        // responder-chain 无法启动宿主 App 时，用户手动打开仍能继续请求。
        // currentSettings 同时充当幂等门：取消 recognitionTask 后的迟到回调
        // 不会重复发送 dictationFailed 或覆盖后续会话。
        guard let settings = currentSettings,
              !currentSessionId.isEmpty,
              settings.session == currentSessionId else { return }
        let failedSession = settings.session
        let refreshedSettings = DictationSettings(
            language: settings.language,
            whisper: settings.whisper,
            translateEnabled: settings.translateEnabled,
            translateTarget: settings.translateTarget,
            selectedText: settings.selectedText,
            keyboardType: settings.keyboardType,
            session: settings.session
        )
        if !DarwinBridge.requeueDictationSettingsIfNotSuperseded(refreshedSettings) {
            print("[BGDictation] Request was superseded or could not be requeued")
        }

        // 停止录音相关资源
        silenceTimer?.cancel()
        silenceTimer = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        state = .idle
        cleanupAudio()

        currentSettings = nil
        currentSessionId = ""
        recognizedText = ""
        stopDictationObserver = nil

        if isPipStandbyEnabled && sharedDefaults.bool(forKey: pipStandbyKey) {
            activateBackgroundAudioSession()
            silentPlayer.stop()
            silentPlayer.start()
        } else {
            silentPlayer.stop()
        }

        // 通知键盘：后台识别失败，降级到前台
        DarwinBridge.postSessionNotification(
            base: DarwinNotificationName.dictationFailed,
            session: failedSession
        )

        print("[BGDictation] dictationFailed sent, keyboard will fall back to URL Scheme")
    }

    // MARK: - 录音

    private func startRecording(settings: DictationSettings) {
        recognizedText = ""
        state = .recording
        let recordingSession = settings.session
        let recordingGeneration = sessionGeneration

        // ★ 关键修复：停止 SilentAudioPlayer！
        // 之前不暂停，导致播放器的噪声被麦克风录进去，干扰语音识别
        // 录音期间 AVAudioEngine 保持 audio session active，app 不会被挂起
        silentPlayer.stop()
        print("[BGDictation] SilentAudioPlayer stopped for recording")

        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: settings.language))

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            print("[BGDictation] Speech recognizer not available, falling back to foreground")
            cleanupForFallback()
            return
        }

        let engine = AVAudioEngine()
        audioEngine = engine

        do {
            let session = AVAudioSession.sharedInstance()
            // ★ 不改变 category options！和待命模式完全一致
            // 只改 mode（whisper 用 .voiceChat 提升语音质量）
            if settings.whisper {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers])
            } else {
                try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers])
            }
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let req = recognitionRequest else {
                print("[BGDictation] Failed to create recognition request, falling back")
                cleanupForFallback()
                return
            }
            req.shouldReportPartialResults = TextProcessor.shared.livePreviewEnabled
            req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

            recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
                Task { @MainActor in
                    guard let self = self else { return }
                    guard self.state == .recording,
                          self.currentSessionId == recordingSession,
                          self.sessionGeneration == recordingGeneration else { return }
                    if let result = result {
                        let text = result.bestTranscription.formattedString
                        self.recognizedText = text
                        self.lastTextUpdateTime = CFAbsoluteTimeGetCurrent()
                        print("[BGDictation] Recognized: \(text.prefix(50))")
                    }
                    if let error = error as? NSError, error.code != 203 {
                        print("[BGDictation] Recognition error: \(error.code) - \(error.localizedDescription)")
                        if self.recognizedText.isEmpty {
                            // 没识别到文字，降级到前台
                            self.cleanupForFallback()
                        } else {
                            // 有部分文字，发送已有结果
                            self.stopRecording()
                        }
                    }
                    if result?.isFinal == true {
                        print("[BGDictation] Recognition final")
                        self.stopRecording()
                    }
                }
            }

            let inputNode = engine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            // ★ 安全检查：音频格式必须有效
            guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
                print("[BGDictation] Invalid audio format (sampleRate=0), falling back")
                cleanupForFallback()
                return
            }

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                req.append(buffer)
            }

            engine.prepare()
            try engine.start()

            lastTextUpdateTime = CFAbsoluteTimeGetCurrent()
            startSilenceTimer(
                session: recordingSession,
                generation: recordingGeneration
            )

            print("[BGDictation] Recording started, format: \(recordingFormat.sampleRate)Hz, \(recordingFormat.channelCount)ch")

        } catch {
            print("[BGDictation] Failed to start recording: \(error.localizedDescription), falling back")
            cleanupForFallback()
        }
    }

    func stopRecording() {
        guard state == .recording else { return }
        state = .processing

        silenceTimer?.cancel()
        silenceTimer = nil

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        let resultText = recognizedText
        let settings = currentSettings
        let generation = sessionGeneration

        DarwinBridge.postNotification(DarwinNotificationName.dictationStopped)

        if resultText.isEmpty {
            DarwinBridge.writeError("未识别到语音", session: currentSessionId)
            finishRecording(expectedSession: currentSessionId, generation: generation)
        } else {
            let selectedText = settings?.selectedText
            let keyboardType = settings?.keyboardType ?? 0
            let hadSelectedText = selectedText != nil && !(selectedText?.isEmpty ?? true)
            let language = settings?.language ?? "zh-CN"
            let translateEnabled = settings?.translateEnabled ?? false
            let translateTarget = settings?.translateTarget ?? "en-US"
            let session = currentSessionId
            let voiceEditEnabled = TextProcessor.shared.voiceEditEnabled

            Task { [weak self] in
                guard let self = self else { return }
                let processed = await TextProcessor.shared.process(
                    resultText,
                    selectedText: selectedText,
                    keyboardType: keyboardType,
                    language: language,
                    translateEnabled: translateEnabled,
                    translateTarget: translateTarget
                )

                guard self.currentSessionId == session,
                      self.sessionGeneration == generation else {
                    print("[BGDictation] Dropping superseded session result")
                    return
                }

                switch processed {
                case .insert(let text):
                    DarwinBridge.writeTranscription(
                        text,
                        session: session,
                        deleteSelected: hadSelectedText && voiceEditEnabled
                    )
                case .deleteSelection:
                    DarwinBridge.writeTranscription(
                        "",
                        session: session,
                        deleteSelected: true
                    )
                case .failure(let reason):
                    let message = reason == .emptyInput ? "未识别到语音" : "文字处理后没有可输入内容"
                    DarwinBridge.writeError(message, session: session)
                }
                self.finishRecording(expectedSession: session, generation: generation)
            }
        }

        print("[BGDictation] Recording stopped, result: \(resultText.count) chars")
    }

    private func finishRecording(expectedSession: String, generation: UInt) {
        guard currentSessionId == expectedSession,
              sessionGeneration == generation else { return }
        // ★ 立即恢复，不要延迟！
        state = .idle
        cleanupAudio()

        currentSettings = nil
        currentSessionId = ""
        recognizedText = ""
        stopDictationObserver = nil

        if isPipStandbyEnabled && sharedDefaults.bool(forKey: pipStandbyKey) {
            activateBackgroundAudioSession()
            silentPlayer.stop()
            silentPlayer.start()
        } else {
            silentPlayer.stop()
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }

        print("[BGDictation] Finished, silent player restarted, back to standby")
    }

    // MARK: - 静音自动停止

    private func startSilenceTimer(session: String, generation: UInt) {
        silenceTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self = self,
                      self.state == .recording,
                      self.currentSessionId == session,
                      self.sessionGeneration == generation else { return }

                let silence = CFAbsoluteTimeGetCurrent() - self.lastTextUpdateTime
                if silence > 3.0 && !self.recognizedText.isEmpty {
                    print("[BGDictation] Silence detected (\(silence)s)")
                    self.stopRecording()
                }
            }
        }
        timer.resume()
        silenceTimer = timer
    }

    // MARK: - 供 DictationViewModel 调用

    /// 录音前停止静音播放器（避免噪声干扰麦克风）
    /// DictationViewModel 在 URL Scheme 降级路径录音前调用
    func stopSilentPlayerForRecording() {
        silentPlayer.stop()
        print("[BGDictation] SilentAudioPlayer stopped (called by DictationViewModel)")
    }

    // MARK: - 清理

    private func cleanupAudio() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        audioEngine = nil
    }
}
