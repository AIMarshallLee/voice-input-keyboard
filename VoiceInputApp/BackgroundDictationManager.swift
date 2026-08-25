import Foundation
import AVFoundation
import Speech

/// 宿主 App 仍在运行时承接键盘会话，并在用户主动开始录音后支持合法的
/// 后台录音。发布版不使用近静音音频或合成 PiP 欺骗系统保活。
@MainActor
class BackgroundDictationManager: ObservableObject {

    static let shared = BackgroundDictationManager()

    // MARK: - 状态

    enum State {
        case idle           // 待命中
        case recording      // 正在录音
        case finalizing     // 已结束音频输入，等待 Speech 最后一帧
        case processing     // 正在处理结果
    }

    @Published private(set) var state: State = .idle

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

    // Darwin 通知监听
    private var startDictationObserver: DarwinNotificationObserver?
    private var stopDictationObserver: DarwinNotificationObserver?

    // 当前会话
    private var currentSessionId = ""
    private var currentSettings: DictationSettings?
    private var sessionGeneration: UInt = 0
    private var processingTask: Task<Void, Never>?
    private var publishesLivePartials = true
    private let liveStatePublisher = DictationLiveStatePublisher()

    // MARK: - 初始化

    private init() {
        setupDarwinObservers()
        setupAudioInterruptionHandling()
    }

    /// App 冷启动时先撤销可能遗留的旧快照。PiP 必须由用户在当前前台会话
    /// 明确开启，真正 active 后才会重新发布 standby readiness。
    func autoRestoreIfNeeded() {
        if !PiPStandbyManager.shared.isActive {
            DarwinBridge.clearReadiness()
            stopHeartbeat()
        }
    }

    deinit {
        heartbeatTimer?.cancel()
    }

    // MARK: - 音频中断处理

    /// 监听电话、Siri、路由切换和媒体服务重置。录音被中断后明确结束本次
    /// 会话，不把中断前的 partial 当成完整结果，也不擅自重新开麦。
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
                self.failActiveRecording(message: "录音被系统中断，请重试")
            case .ended:
                let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let shouldResume = AVAudioSession.InterruptionOptions(
                    rawValue: optionsValue
                ).contains(.shouldResume)
                print("[BGDictation] Audio interruption ended, shouldResume=\(shouldResume)")
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
                print("[BGDictation] Audio route changed")
                self.failActiveRecording(message: "音频输入设备已变化，请重试")
            }
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            print("[BGDictation] Audio media services were reset")
            self.failActiveRecording(message: "音频服务已重置，请重新录音")
            self.cleanupAudio()
        }
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
                if DarwinBridge.isSessionCancelled(session: session) {
                    self.cancelActiveSession(session: session)
                } else {
                    self.stopRecording()
                }
            }
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
        // 宿主仍可运行时尝试直接录音；只有音频引擎成功后才确认 started。

        guard PiPStandbyManager.shared.isActive else {
            // readiness 文件即使因进程被系统冻结而短暂残留，也不能让宿主在
            // 没有真实后台执行资格时消费会话。键盘会自动降级到冷启动。
            DarwinBridge.clearReadiness()
            print("[BGDictation] Ignoring in-place request without active PiP")
            return
        }

        guard let pending = DarwinBridge.peekPendingDictationSettings() else {
            print("[BGDictation] No fresh settings request")
            return
        }

        // 先查看 session，再只消费完全匹配且未过期的请求。
        guard let settings = DarwinBridge.readAndConsumeDictationSettings(
                expectedSession: pending.session
              ) else {
            print("[BGDictation] Pending settings changed before consume")
            return
        }
        guard !DarwinBridge.isSessionCancelled(session: settings.session) else {
            print("[BGDictation] Ignoring cancelled session")
            return
        }

        // 只有新请求已经被原子取得后才替换旧会话，避免 peek/consume 竞态
        // 既杀掉旧会话又漏掉新通知。
        if state != .idle {
            print("[BGDictation] New request supersedes the active session")
            cancelCurrentSessionForSupersedingRequest()
        }

        currentSessionId = settings.session
        currentSettings = settings
        sessionGeneration &+= 1
        observeStopRequest(for: settings.session)
        guard liveStatePublisher.publishImmediately(
            phase: .starting,
            session: settings.session
        ) else {
            if DarwinBridge.isSessionCancelled(session: settings.session) {
                cancelActiveSession(session: settings.session)
            } else {
                cleanupForFallback()
            }
            return
        }

        print("[BGDictation] Starting background recognition, session=\(settings.session.prefix(8))")

        // 开始录音。
        guard startRecording(settings: settings) else { return }

        // 只有 AVAudioEngine 真正启动成功后才确认，防止键盘进入假聆听状态。
        DarwinBridge.postSessionNotification(
            base: DarwinNotificationName.dictationStarted,
            session: settings.session
        )
        print("[BGDictation] dictationStarted sent after audio engine start")
    }

    /// 键盘扩展重建后可能在旧会话尚未完成时创建新会话。最新请求接管时，
    /// 使旧异步处理失效并释放音频资源；旧任务之后不得重配 audio session。
    private func cancelCurrentSessionForSupersedingRequest() {
        let supersededSession = currentSessionId
        sessionGeneration &+= 1
        processingTask?.cancel()
        processingTask = nil
        silenceTimer?.cancel()
        silenceTimer = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        cleanupAudio()

        state = .idle
        stopHeartbeat()
        PiPStandbyManager.shared.returnToStandby()
        currentSettings = nil
        currentSessionId = ""
        recognizedText = ""
        stopDictationObserver = nil
        if !supersededSession.isEmpty {
            liveStatePublisher.cancelPending(for: supersededSession)
            DarwinBridge.writeError(
                "语音会话已被新的请求替代",
                session: supersededSession
            )
        }
        DarwinBridge.postNotification(DarwinNotificationName.dictationStopped)
    }

    /// 取消墓碑已经由键盘先写入。这里只负责让录音、finalizing 和异步文字
    /// 处理全部失效；不再写终态结果，避免超时后出现迟到回填。
    private func cancelActiveSession(session: String) {
        guard currentSessionId == session else { return }
        sessionGeneration &+= 1
        processingTask?.cancel()
        processingTask = nil
        liveStatePublisher.cancelPending(for: session)
        silenceTimer?.cancel()
        silenceTimer = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        cleanupAudio()

        state = .idle
        stopHeartbeat()
        PiPStandbyManager.shared.returnToStandby()
        currentSettings = nil
        currentSessionId = ""
        recognizedText = ""
        stopDictationObserver = nil
        DarwinBridge.clearLiveState(session: session)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        DarwinBridge.postNotification(DarwinNotificationName.dictationStopped)
        print("[BGDictation] Cancelled session \(session.prefix(8))")
    }

    private func failActiveRecording(message: String) {
        guard state == .recording || state == .finalizing,
              !currentSessionId.isEmpty else { return }
        let failedSession = currentSessionId
        sessionGeneration &+= 1
        processingTask?.cancel()
        processingTask = nil
        liveStatePublisher.cancelPending(for: failedSession)
        silenceTimer?.cancel()
        silenceTimer = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        cleanupAudio()
        if !DarwinBridge.isSessionCancelled(session: failedSession) {
            _ = DarwinBridge.writeError(message, session: failedSession)
        }
        state = .idle
        stopHeartbeat()
        PiPStandbyManager.shared.returnToStandby()
        currentSettings = nil
        currentSessionId = ""
        recognizedText = ""
        stopDictationObserver = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        DarwinBridge.postNotification(DarwinNotificationName.dictationStopped)
    }

    /// 后台识别失败时回写同一会话，用户打开 VoType 后由前台页继续。
    private func cleanupForFallback() {
        print("[BGDictation] Cleaning up for foreground fallback")

        // Path A 已经消费了设置。先把同一会话刷新后写回 App Group，确保
        // 用户手动打开宿主 App 时仍能继续请求。
        // currentSettings 同时充当幂等门：取消 recognitionTask 后的迟到回调
        // 不会重复发送 dictationFailed 或覆盖后续会话。
        guard let settings = currentSettings,
              !currentSessionId.isEmpty,
              settings.session == currentSessionId else { return }
        let failedSession = settings.session
        if DarwinBridge.isSessionCancelled(session: failedSession) {
            cancelActiveSession(session: failedSession)
            return
        }
        liveStatePublisher.cancelPending(for: failedSession)
        let refreshedSettings = DictationSettings(
            language: settings.language,
            whisper: settings.whisper,
            translateEnabled: settings.translateEnabled,
            translateTarget: settings.translateTarget,
            selectedText: settings.selectedText,
            keyboardType: settings.keyboardType,
            session: settings.session,
            timestamp: settings.timestamp
        )
        let didRequeue = DarwinBridge.requeueDictationSettingsIfNotSuperseded(
            refreshedSettings
        )
        if !didRequeue {
            print("[BGDictation] Request was superseded or could not be requeued")
        }

        // 停止录音相关资源
        silenceTimer?.cancel()
        silenceTimer = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        processingTask?.cancel()
        processingTask = nil

        state = .idle
        stopHeartbeat()
        cleanupAudio()
        PiPStandbyManager.shared.returnToStandby()

        currentSettings = nil
        currentSessionId = ""
        recognizedText = ""
        stopDictationObserver = nil

        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )

        if didRequeue {
            liveStatePublisher.publishImmediately(
                phase: .starting,
                session: failedSession
            )
        } else {
            DarwinBridge.clearLiveState(session: failedSession)
        }

        // 通知键盘：后台识别失败，降级到前台
        DarwinBridge.postSessionNotification(
            base: DarwinNotificationName.dictationFailed,
            session: failedSession
        )

        print("[BGDictation] dictationFailed sent; foreground handoff required")
    }

    // MARK: - 录音

    @discardableResult
    private func startRecording(settings: DictationSettings) -> Bool {
        guard !DarwinBridge.isSessionCancelled(session: settings.session) else {
            cancelActiveSession(session: settings.session)
            return false
        }
        recognizedText = ""
        state = .recording
        let recordingSession = settings.session
        let recordingGeneration = sessionGeneration

        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: settings.language))

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            print("[BGDictation] Speech recognizer not available, falling back to foreground")
            cleanupForFallback()
            return false
        }

        let engine = AVAudioEngine()
        audioEngine = engine

        do {
            let session = AVAudioSession.sharedInstance()
            // 耳语模式使用 voiceChat；其余会话使用默认录音模式。
            if settings.whisper {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers])
            } else {
                try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers])
            }
            try session.setActive(true)

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let req = recognitionRequest else {
                print("[BGDictation] Failed to create recognition request, falling back")
                cleanupForFallback()
                return false
            }
            // 始终请求 Speech partial，保证内部识别和静音超时可靠；设置开关
            // 仅控制是否把中间文字写入 App Group 给键盘展示。
            publishesLivePartials = TextProcessor.shared.livePreviewEnabled
            req.shouldReportPartialResults = true
            req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

            recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
                Task { @MainActor in
                    guard let self = self else { return }
                    guard self.state == .recording || self.state == .finalizing,
                          self.currentSessionId == recordingSession,
                          self.sessionGeneration == recordingGeneration else { return }
                    if let result = result {
                        let text = result.bestTranscription.formattedString
                        self.recognizedText = text
                        self.lastTextUpdateTime = CFAbsoluteTimeGetCurrent()
                        PiPStandbyManager.shared.setRecording(text: text)
                        if self.publishesLivePartials {
                            self.liveStatePublisher.publishPartial(
                                text,
                                session: recordingSession
                            )
                        }
                        print("[BGDictation] Recognized: \(text.prefix(50))")
                    }
                    if let error = error as? NSError, error.code != 203 {
                        print("[BGDictation] Recognition error: \(error.code) - \(error.localizedDescription)")
                        if self.state == .finalizing {
                            self.finishSpeechRecognition(
                                expectedSession: recordingSession,
                                generation: recordingGeneration
                            )
                        } else if self.recognizedText.isEmpty {
                            // 没识别到文字，降级到前台
                            self.cleanupForFallback()
                        } else {
                            // 有部分文字，发送已有结果
                            self.stopRecording()
                        }
                    }
                    if result?.isFinal == true {
                        print("[BGDictation] Recognition final")
                        if self.state == .finalizing {
                            self.finishSpeechRecognition(
                                expectedSession: recordingSession,
                                generation: recordingGeneration
                            )
                        } else {
                            self.stopRecording()
                        }
                    }
                }
            }

            let inputNode = engine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            // ★ 安全检查：音频格式必须有效
            guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
                print("[BGDictation] Invalid audio format (sampleRate=0), falling back")
                cleanupForFallback()
                return false
            }

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                req.append(buffer)
            }

            engine.prepare()
            guard !DarwinBridge.isSessionCancelled(session: recordingSession) else {
                cancelActiveSession(session: recordingSession)
                return false
            }
            try engine.start()

            guard !DarwinBridge.isSessionCancelled(session: recordingSession) else {
                cancelActiveSession(session: recordingSession)
                return false
            }

            lastTextUpdateTime = CFAbsoluteTimeGetCurrent()
            startSilenceTimer(
                session: recordingSession,
                generation: recordingGeneration
            )
            guard liveStatePublisher.publishImmediately(
                phase: .listening,
                session: recordingSession
            ) else {
                if DarwinBridge.isSessionCancelled(session: recordingSession) {
                    cancelActiveSession(session: recordingSession)
                } else {
                    cleanupForFallback()
                }
                return false
            }
            startHeartbeat()
            PiPStandbyManager.shared.setRecording()

            print("[BGDictation] Recording started, format: \(recordingFormat.sampleRate)Hz, \(recordingFormat.channelCount)ch")
            return true

        } catch {
            print("[BGDictation] Failed to start recording: \(error.localizedDescription), falling back")
            cleanupForFallback()
            return false
        }
    }

    func stopRecording() {
        guard state == .recording else { return }
        if DarwinBridge.isSessionCancelled(session: currentSessionId) {
            cancelActiveSession(session: currentSessionId)
            return
        }
        state = .finalizing

        silenceTimer?.cancel()
        silenceTimer = nil

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        let session = currentSessionId
        let generation = sessionGeneration
        liveStatePublisher.publishImmediately(
            phase: .processing,
            partialTranscript: publishesLivePartials ? recognizedText : "",
            session: session
        )
        PiPStandbyManager.shared.setProcessing(
            text: publishesLivePartials ? recognizedText : ""
        )

        DarwinBridge.postNotification(DarwinNotificationName.dictationStopped)

        // endAudio 后给 Speech 一个很短且有界的窗口提交最后一帧，避免直接
        // cancel 截掉句尾。isFinal 回调会提前触发同一个幂等完成函数。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.finishSpeechRecognition(
                expectedSession: session,
                generation: generation
            )
        }
    }

    private func finishSpeechRecognition(expectedSession: String, generation: UInt) {
        guard state == .finalizing,
              currentSessionId == expectedSession,
              sessionGeneration == generation else { return }
        state = .processing
        recognitionTask?.cancel()

        if DarwinBridge.isSessionCancelled(session: expectedSession) {
            cancelActiveSession(session: expectedSession)
            return
        }

        let resultText = recognizedText
        let settings = currentSettings

        if resultText.isEmpty {
            DarwinBridge.writeError("未识别到语音", session: expectedSession)
            finishRecording(expectedSession: expectedSession, generation: generation)
        } else {
            let selectedText = settings?.selectedText
            let keyboardType = settings?.keyboardType ?? 0
            let hadSelectedText = selectedText != nil && !(selectedText?.isEmpty ?? true)
            let language = settings?.language ?? "zh-CN"
            let translateEnabled = settings?.translateEnabled ?? false
            let translateTarget = settings?.translateTarget ?? "en-US"
            let session = expectedSession
            let voiceEditEnabled = TextProcessor.shared.voiceEditEnabled

            processingTask?.cancel()
            processingTask = Task { [weak self] in
                guard let self = self else { return }
                let processed = await TextProcessor.shared.process(
                    resultText,
                    selectedText: selectedText,
                    keyboardType: keyboardType,
                    language: language,
                    translateEnabled: translateEnabled,
                    translateTarget: translateTarget
                )

                guard !Task.isCancelled,
                      !DarwinBridge.isSessionCancelled(session: session),
                      self.currentSessionId == session,
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
                self.processingTask = nil
                self.finishRecording(expectedSession: session, generation: generation)
            }
        }

        print("[BGDictation] Recording stopped, result: \(resultText.count) chars")
    }

    private func finishRecording(expectedSession: String, generation: UInt) {
        guard currentSessionId == expectedSession,
              sessionGeneration == generation else { return }
        liveStatePublisher.cancelPending(for: expectedSession)
        processingTask?.cancel()
        processingTask = nil
        // ★ 立即恢复，不要延迟！
        state = .idle
        stopHeartbeat()
        cleanupAudio()
        PiPStandbyManager.shared.returnToStandby()

        currentSettings = nil
        currentSessionId = ""
        recognizedText = ""
        stopDictationObserver = nil

        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )

        print("[BGDictation] Finished and released audio session")
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

                if DarwinBridge.isSessionCancelled(session: session) {
                    self.cancelActiveSession(session: session)
                    return
                }

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

    // MARK: - 清理

    private func cleanupAudio() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        audioEngine = nil
    }
}
