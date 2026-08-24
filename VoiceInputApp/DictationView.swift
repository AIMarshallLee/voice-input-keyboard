import SwiftUI
import AVFoundation
import Speech
import UIKit

// MARK: - ViewModel

/// 容器 App 语音听写 ViewModel
/// 用户打开 VoType 后承接键盘留存的听写请求；录音开始后可切回原输入框。
@MainActor
class DictationViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var liveText = ""
    @Published var statusMessage = "准备中..."
    @Published var hasResult = false
    @Published var permissionError: String?
    @Published var canExit = false

    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizedText = ""
    private var silenceTimer: Timer?
    private var lastTextUpdateTime: Date?

    // 心跳定时器:每 0.5s 写一次心跳,让键盘知道主 App 存活
    private var heartbeatTimer: DispatchSourceTimer?

    private(set) var languageID = "zh-CN"
    private(set) var whisperMode = false
    private(set) var translateEnabled = false
    private(set) var translateTarget = "en-US"
    private(set) var selectedText: String?
    private(set) var sessionId = ""
    private(set) var keyboardType: Int = 0
    private(set) var hasValidSettings = false
    private var didWriteTerminalResult = false
    private var isProcessingResult = false
    private var isFinalizingRecognition = false
    private var recognitionFinalizeWorkItem: DispatchWorkItem?
    private var processingTask: Task<Void, Never>?
    private var lifecycleGeneration: UInt = 0
    private var publishesLivePartials = true
    private let liveStatePublisher = DictationLiveStatePublisher()
    private var stopRequestObserver: DarwinNotificationObserver?
    private var audioInterruptionObserver: NSObjectProtocol?
    private var mediaServicesResetObserver: NSObjectProtocol?
    private var audioRouteObserver: NSObjectProtocol?

    // MARK: - 从 URL 加载设置

    func loadSettings(from url: URL?, expectedSession explicitSession: String? = nil) {
        let expectedSession: String?
        if let explicitSession,
           DictationConstants.isValidSession(explicitSession) {
            expectedSession = explicitSession
        } else if let url,
           url.scheme == DictationConstants.urlScheme,
           url.host == DictationConstants.dictationPath,
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let value = components.queryItems?.first(where: {
               $0.name == DictationConstants.paramSession
           })?.value,
           DictationConstants.isValidSession(value) {
            expectedSession = value
        } else {
            expectedSession = nil
        }

        let settings: DictationSettings?
        if let expectedSession {
            settings = DarwinBridge.readAndConsumeDictationSettings(
                expectedSession: expectedSession
            )
        } else if url == nil,
                  let pending = DarwinBridge.peekPendingDictationSettings() {
            settings = DarwinBridge.readAndConsumeDictationSettings(
                expectedSession: pending.session
            )
        } else {
            settings = nil
        }

        guard let settings,
              DictationConstants.isValidSession(settings.session),
              !DarwinBridge.isSessionCancelled(session: settings.session) else {
            hasValidSettings = false
            sessionId = ""
            speechRecognizer = nil
            return
        }

        hasValidSettings = true
        lifecycleGeneration &+= 1
        sessionId = settings.session
        languageID = settings.language
        whisperMode = settings.whisper
        translateEnabled = settings.translateEnabled
        translateTarget = settings.translateTarget
        selectedText = settings.selectedText
        keyboardType = settings.keyboardType
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: languageID))
        configureStopRequestObserver()
        configureAudioObservers()
        liveStatePublisher.publishImmediately(
            phase: .starting,
            session: settings.session
        )
    }

    private func configureStopRequestObserver() {
        guard let name = DarwinBridge.sessionNotificationName(
            base: DarwinNotificationName.requestStopDictation,
            session: sessionId
        ) else {
            stopRequestObserver = nil
            return
        }
        stopRequestObserver = DarwinNotificationObserver(name: name) { [weak self] in
            Task { @MainActor in
                guard let self, self.hasValidSettings else { return }
                if DarwinBridge.isSessionCancelled(session: self.sessionId) {
                    self.cancelActiveSession()
                } else if self.isRecording {
                    self.stopRecording()
                } else if self.isFinalizingRecognition
                            || self.isProcessingResult
                            || self.didWriteTerminalResult {
                    // stop 是幂等操作；finalizing/processing 已经不再收音，不能
                    // 用一个 error 覆盖正在生成的正确终态。
                    return
                } else {
                    self.fail("语音输入已取消")
                }
            }
        }
    }

    private func configureAudioObservers() {
        removeAudioObservers()
        audioInterruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: typeValue) == .began else { return }
            self.abortRecording(message: "录音被系统中断，请重试")
        }
        mediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.abortRecording(message: "音频服务已重置，请重新录音")
        }
        audioRouteObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
                  reason == .oldDeviceUnavailable else { return }
            self?.abortRecording(message: "音频输入设备已断开，请重试")
        }
    }

    private func removeAudioObservers() {
        [audioInterruptionObserver, mediaServicesResetObserver, audioRouteObserver]
            .compactMap { $0 }
            .forEach { NotificationCenter.default.removeObserver($0) }
        audioInterruptionObserver = nil
        mediaServicesResetObserver = nil
        audioRouteObserver = nil
    }

    // MARK: - 权限检查 + 自动开始录音

    func checkPermissionsAndStart() {
        guard hasValidSettings else {
            permissionError = "听写请求已过期，请返回键盘重试"
            statusMessage = permissionError ?? "听写请求无效"
            canExit = true
            return
        }
        let expectedSession = sessionId
        let generation = lifecycleGeneration
        let speechStatus = SFSpeechRecognizer.authorizationStatus()

        if speechStatus != .authorized {
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.canStartRecording(
                            expectedSession: expectedSession,
                            generation: generation
                          ) else { return }
                    if status != .authorized {
                        self.fail("请到设置中允许语音识别权限")
                    } else {
                        self.checkMicPermission(
                            expectedSession: expectedSession,
                            generation: generation
                        )
                    }
                }
            }
        } else {
            checkMicPermission(
                expectedSession: expectedSession,
                generation: generation
            )
        }
    }

    private func checkMicPermission(expectedSession: String, generation: UInt) {
        guard canStartRecording(
            expectedSession: expectedSession,
            generation: generation
        ) else { return }
        let micStatus = AVAudioSession.sharedInstance().recordPermission
        if micStatus != .granted {
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.canStartRecording(
                            expectedSession: expectedSession,
                            generation: generation
                          ) else { return }
                    if !granted {
                        self.fail("请到设置中允许麦克风权限")
                    } else {
                        self.startRecording(
                            expectedSession: expectedSession,
                            generation: generation
                        )
                    }
                }
            }
        } else {
            startRecording(
                expectedSession: expectedSession,
                generation: generation
            )
        }
    }

    private func canStartRecording(
        expectedSession: String,
        generation: UInt
    ) -> Bool {
        hasValidSettings
            && !didWriteTerminalResult
            && !isRecording
            && !isFinalizingRecognition
            && !isProcessingResult
            && sessionId == expectedSession
            && lifecycleGeneration == generation
            && !DarwinBridge.isSessionCancelled(session: expectedSession)
    }

    // MARK: - 录音

    func startRecording() {
        startRecording(
            expectedSession: sessionId,
            generation: lifecycleGeneration
        )
    }

    private func startRecording(expectedSession: String, generation: UInt) {
        guard canStartRecording(
            expectedSession: expectedSession,
            generation: generation
        ) else { return }
        recognizedText = ""
        liveText = ""

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            fail("语音识别不可用，请检查网络或设备端识别支持")
            return
        }

        let engine = AVAudioEngine()
        audioEngine = engine

        do {
            let session = AVAudioSession.sharedInstance()
            // 不使用 .duckOthers，避免录音时压低其他 App 的音频。
            if whisperMode {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers])
            } else {
                try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers])
            }
            try session.setActive(true)

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let req = recognitionRequest else {
                fail("无法创建语音识别请求")
                cleanupAudioOnly()
                return
            }
            // Speech partial 始终开启，供 recognizedText、静音超时和最终结果使用；
            // 用户的 livePreview 开关只决定是否把中间文字发布给键盘。
            publishesLivePartials = TextProcessor.shared.livePreviewEnabled
            req.shouldReportPartialResults = true
            req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

            recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self = self,
                          self.sessionId == expectedSession,
                          self.lifecycleGeneration == generation,
                          self.isRecording || self.isFinalizingRecognition else { return }
                    if let result = result {
                        let text = result.bestTranscription.formattedString
                        self.recognizedText = text
                        self.liveText = text
                        self.lastTextUpdateTime = Date()
                        if self.publishesLivePartials {
                            self.liveStatePublisher.publishPartial(
                                text,
                                session: self.sessionId
                            )
                        }
                    }
                    if let error = error as? NSError, error.code != 203 {
                        if self.isFinalizingRecognition {
                            self.finishRecognition(
                                expectedSession: expectedSession,
                                generation: generation
                            )
                        } else {
                            self.stopRecording()
                        }
                    }
                    if result?.isFinal == true {
                        if self.isFinalizingRecognition {
                            self.finishRecognition(
                                expectedSession: expectedSession,
                                generation: generation
                            )
                        } else {
                            self.stopRecording()
                        }
                    }
                }
            }

            let inputNode = engine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
                fail("麦克风音频格式不可用，请检查输入设备")
                cleanupAudioOnly()
                return
            }

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                req.append(buffer)
            }

            engine.prepare()
            guard canStartRecording(
                expectedSession: expectedSession,
                generation: generation
            ) else {
                cancelActiveSession()
                return
            }
            try engine.start()

            guard canStartRecording(
                expectedSession: expectedSession,
                generation: generation
            ) else {
                cancelActiveSession()
                return
            }

            isRecording = true
            statusMessage = "正在聆听..."
            lastTextUpdateTime = Date()
            startSilenceTimer()
            guard liveStatePublisher.publishImmediately(
                phase: .listening,
                session: sessionId
            ) else {
                if DarwinBridge.isSessionCancelled(session: sessionId) {
                    cancelActiveSession()
                } else {
                    abortRecording(message: "无法同步语音会话，请重试")
                }
                return
            }

            // 写入心跳 + 发送 dictationStarted 通知 (键盘收到后取消 5s 超时)
            DarwinBridge.writeHeartbeat()
            DarwinBridge.postSessionNotification(
                base: DarwinNotificationName.dictationStarted,
                session: sessionId
            )
            startHeartbeat()

        } catch {
            fail("启动失败：\(error.localizedDescription)")
            cleanup()
        }
    }

    private func fail(_ message: String) {
        permissionError = message
        statusMessage = message
        canExit = true
        if !didWriteTerminalResult, !sessionId.isEmpty {
            liveStatePublisher.cancelPending(for: sessionId)
            if DarwinBridge.isSessionCancelled(session: sessionId) {
                DarwinBridge.clearLiveState(session: sessionId)
            } else {
                didWriteTerminalResult = DarwinBridge.writeError(
                    message,
                    session: sessionId
                )
            }
        }
        lifecycleGeneration &+= 1
        hasValidSettings = false
    }

    func stopRecording() {
        guard isRecording else { return }
        if DarwinBridge.isSessionCancelled(session: sessionId) {
            cancelActiveSession()
            return
        }
        isRecording = false
        isFinalizingRecognition = true

        silenceTimer?.invalidate()
        silenceTimer = nil

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        statusMessage = "正在完成识别..."
        liveStatePublisher.publishImmediately(
            phase: .processing,
            partialTranscript: publishesLivePartials ? recognizedText : "",
            session: sessionId
        )

        // 通知键盘:听写已停止
        DarwinBridge.postNotification(DarwinNotificationName.dictationStopped)

        recognitionFinalizeWorkItem?.cancel()
        let expectedSession = sessionId
        let generation = lifecycleGeneration
        let workItem = DispatchWorkItem { [weak self] in
            self?.finishRecognition(
                expectedSession: expectedSession,
                generation: generation
            )
        }
        recognitionFinalizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.45,
            execute: workItem
        )
    }

    private func finishRecognition(expectedSession: String, generation: UInt) {
        guard isFinalizingRecognition,
              sessionId == expectedSession,
              lifecycleGeneration == generation else { return }
        isFinalizingRecognition = false
        recognitionFinalizeWorkItem?.cancel()
        recognitionFinalizeWorkItem = nil
        recognitionTask?.cancel()

        if DarwinBridge.isSessionCancelled(session: sessionId) {
            cancelActiveSession()
            return
        }

        let resultText = recognizedText
        let hadSelectedText = selectedText != nil && !(selectedText?.isEmpty ?? true)
        let kbType = keyboardType

        if resultText.isEmpty {
            liveStatePublisher.cancelPending(for: sessionId)
            let wroteResult = DarwinBridge.writeError("未识别到语音", session: sessionId)
            didWriteTerminalResult = wroteResult
            if wroteResult {
                statusMessage = "未识别到语音"
                hasResult = true
            } else {
                permissionError = "无法写入共享结果，请检查 App Group 配置"
                statusMessage = permissionError ?? "无法写入结果"
                canExit = true
            }
            transitionToStandby()
        } else {
            statusMessage = "正在处理文字..."
            isProcessingResult = true

            // ★ 关键: 不依赖 self! DictationView 会在 2.5s 后 dismiss,
            // viewModel 可能被释放。把所有需要的值捕获为局部变量,
            // 这样即使 viewModel 被释放,Task 也能正常执行
            let capturedSessionId = sessionId
            let capturedSelectedText = selectedText
            let capturedKbType = kbType
            let capturedResultText = resultText
            let capturedHadSelectedText = hadSelectedText
            let capturedLanguage = languageID
            let capturedTranslateEnabled = translateEnabled
            let capturedTranslateTarget = translateTarget
            let capturedVoiceEditEnabled = TextProcessor.shared.voiceEditEnabled
            let capturedGeneration = lifecycleGeneration

            // 在主 App 中处理文字 (LLM/翻译/格式化/语音编辑)
            // 键盘扩展内存太小,不能跑 LLM
            processingTask = Task { [weak self] in
                let processed = await TextProcessor.shared.process(
                    capturedResultText,
                    selectedText: capturedSelectedText,
                    keyboardType: capturedKbType,
                    language: capturedLanguage,
                    translateEnabled: capturedTranslateEnabled,
                    translateTarget: capturedTranslateTarget
                )

                // 页面关闭会释放 ViewModel，但已经开始的文字处理仍必须把终态
                // 写回 App Group。只有 ViewModel 仍存在且已切换到另一代会话时，
                // 才把这一任务视为过期；IPC cancellation tombstone 是跨生命周期
                // 的最终取消依据。
                let generationIsCurrent = self.map {
                    $0.lifecycleGeneration == capturedGeneration
                        && $0.sessionId == capturedSessionId
                } ?? true
                // 旧任务若已被下一代会话替代，只丢弃旧任务；绝不能借旧任务的
                // 失败分支取消当前新会话。
                guard generationIsCurrent else { return }
                guard !Task.isCancelled,
                      !DarwinBridge.isSessionCancelled(
                          session: capturedSessionId
                      ) else {
                    await MainActor.run {
                        self?.isProcessingResult = false
                        self?.cancelActiveSession()
                    }
                    return
                }

                self?.liveStatePublisher.cancelPending(for: capturedSessionId)
                let wroteResult: Bool
                switch processed {
                case .insert(let text):
                    wroteResult = DarwinBridge.writeTranscription(
                        text,
                        session: capturedSessionId,
                        deleteSelected: capturedHadSelectedText && capturedVoiceEditEnabled
                    )
                case .deleteSelection:
                    wroteResult = DarwinBridge.writeTranscription(
                        "",
                        session: capturedSessionId,
                        deleteSelected: true
                    )
                case .failure(let reason):
                    let message = reason == .emptyInput ? "未识别到语音" : "文字处理后没有可输入内容"
                    wroteResult = DarwinBridge.writeError(message, session: capturedSessionId)
                }

                // 回到主线程更新 UI (如果 viewModel 还活着)
                await MainActor.run {
                    self?.processingTask = nil
                    self?.isProcessingResult = false
                    self?.didWriteTerminalResult = wroteResult
                    if wroteResult {
                        self?.statusMessage = "识别完成 ✓"
                        self?.hasResult = true
                    } else {
                        self?.permissionError = "无法写入共享结果，请检查 App Group 配置"
                        self?.statusMessage = "无法写入结果"
                        self?.canExit = true
                    }
                    self?.transitionToStandby()
                }
            }
        }

        print("[Dictation] Recognition finalized, result: \(resultText.count) chars")
    }

    private func transitionToStandby() {
        let generation = lifecycleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self,
                  self.lifecycleGeneration == generation else { return }
            self.stopHeartbeat()
            self.cleanupAudioOnly()
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    /// 释放一次听写的录音资源。
    private func cleanupAudioOnly() {
        recognitionRequest = nil
        recognitionTask = nil
        audioEngine = nil
        print("[Dictation] Audio resources cleaned")
    }

    private func cancelActiveSession() {
        guard !sessionId.isEmpty else { return }
        lifecycleGeneration &+= 1
        hasValidSettings = false
        recognitionFinalizeWorkItem?.cancel()
        recognitionFinalizeWorkItem = nil
        processingTask?.cancel()
        processingTask = nil
        isRecording = false
        isFinalizingRecognition = false
        isProcessingResult = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        liveStatePublisher.cancelPending(for: sessionId)
        DarwinBridge.clearLiveState(session: sessionId)
        stopHeartbeat()
        cleanupAudioOnly()
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        statusMessage = "已取消"
        canExit = true
    }

    private func abortRecording(message: String) {
        guard isRecording || isFinalizingRecognition else { return }
        recognitionFinalizeWorkItem?.cancel()
        recognitionFinalizeWorkItem = nil
        isRecording = false
        isFinalizingRecognition = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        liveStatePublisher.cancelPending(for: sessionId)
        fail(message)
        DarwinBridge.postNotification(DarwinNotificationName.dictationStopped)
        stopHeartbeat()
        cleanupAudioOnly()
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    // MARK: - 静音自动停止

    private func startSilenceTimer() {
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.isRecording else { return }
                guard let lastUpdate = self.lastTextUpdateTime else { return }

                let silenceDuration = Date().timeIntervalSince(lastUpdate)
                // 如果 3 秒没有新的识别文本,自动停止
                if silenceDuration > 3.0 && !self.recognizedText.isEmpty {
                    self.stopRecording()
                }
            }
        }
    }

    // MARK: - 清理

    func cleanup() {
        if !sessionId.isEmpty,
           DarwinBridge.isSessionCancelled(session: sessionId) {
            cancelActiveSession()
            stopRequestObserver = nil
            removeAudioObservers()
            return
        }
        if !sessionId.isEmpty {
            liveStatePublisher.cancelPending(for: sessionId)
        }
        if isRecording || isFinalizingRecognition {
            isRecording = false
            isFinalizingRecognition = false
            recognitionFinalizeWorkItem?.cancel()
            recognitionFinalizeWorkItem = nil
            silenceTimer?.invalidate()
            silenceTimer = nil
            audioEngine?.stop()
            audioEngine?.inputNode.removeTap(onBus: 0)
            recognitionRequest?.endAudio()
            recognitionTask?.cancel()
            if !didWriteTerminalResult {
                didWriteTerminalResult = DarwinBridge.writeError("已取消", session: sessionId)
            }
            DarwinBridge.postNotification(DarwinNotificationName.dictationStopped)
        } else if hasValidSettings,
                  !didWriteTerminalResult,
                  !isProcessingResult,
                  !sessionId.isEmpty {
            // 权限页或启动阶段被关闭也属于明确取消；不得把 starting 快照
            // 留给键盘等待 TTL。
            didWriteTerminalResult = DarwinBridge.writeError("已取消", session: sessionId)
        }
        stopHeartbeat()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        audioEngine = nil
        stopRequestObserver = nil
        removeAudioObservers()
        if !isProcessingResult {
            lifecycleGeneration &+= 1
            hasValidSettings = false
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    // MARK: - 心跳定时器

    /// 每 0.5s 发一次心跳 Darwin 通知
    /// 录音期间发送心跳，让返回后的键盘知道宿主会话仍在运行。
    private func startHeartbeat() {
        stopHeartbeat()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        timer.schedule(deadline: .now(), repeating: 0.5)
        timer.setEventHandler { DarwinBridge.writeHeartbeat() }
        timer.resume()
        heartbeatTimer = timer
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }
}

// MARK: - View

/// 容器 App 的语音听写页面
/// 用户打开 VoType 后消费键盘留在 App Group 中的会话并开始录音。
struct DictationView: View {
    @StateObject private var viewModel = DictationViewModel()
    @Environment(\.dismiss) var dismiss
    let expectedSession: String
    var url: URL?

    var body: some View {
        ZStack {
            // 背景色
            Color.black.opacity(0.95).ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // 状态图标
                VStack(spacing: 12) {
                    Image(systemName: viewModel.hasResult ? "checkmark.circle.fill" : (viewModel.isRecording ? "waveform.circle.fill" : "mic.circle.fill"))
                        .font(.system(size: 72))
                        .foregroundColor(viewModel.hasResult ? .green : (viewModel.isRecording ? .red : .blue))

                    Text(viewModel.hasResult ? "识别完成" : (viewModel.isRecording ? "正在聆听..." : "语音输入"))
                        .font(.title.bold())
                        .foregroundColor(.white)

                    Text(viewModel.statusMessage)
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                .padding(.top, 20)

                // 实时识别文本
                ScrollView {
                    if viewModel.liveText.isEmpty {
                        Text(viewModel.isRecording ? "等待说话..." : "识别结果将显示在这里")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text(viewModel.liveText)
                            .font(.title3)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                }
                .frame(maxHeight: .infinity)

                // 错误提示
                if let error = viewModel.permissionError {
                    VStack(spacing: 10) {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                        Button("前往系统设置") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                }

                Spacer()

                // 底部操作按钮
                VStack(spacing: 16) {
                    if viewModel.hasResult {
                        Text("文字已就绪，返回键盘即可")
                            .font(.subheadline)
                            .foregroundColor(.blue)
                            .multilineTextAlignment(.center)

                        Button("完成") {
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else if viewModel.isRecording {
                        Button(action: { viewModel.stopRecording() }) {
                            Label("说完,点击停止", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.large)
                        .padding(.horizontal)
                    } else if viewModel.canExit {
                        Button("返回") { dismiss() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    } else if viewModel.permissionError == nil {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("正在启动...")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            viewModel.loadSettings(
                from: url,
                expectedSession: expectedSession
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                viewModel.checkPermissionsAndStart()
            }
        }
        .onChange(of: viewModel.hasResult) { hasResult in
            if hasResult {
                // 录音完成后,2.5s 后自动 dismiss
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    dismiss()
                }
            }
        }
        .onDisappear {
            viewModel.cleanup()
        }
    }
}
