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

    // MARK: - 初始化

    private init() {
        setupDarwinObservers()
        setupAudioInterruptionHandling()
    }

    /// App 启动时调用:权限已授权就自动启用后台保活
    func autoRestoreIfNeeded() {
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

        stopDictationObserver = DarwinNotificationObserver(
            name: DarwinNotificationName.requestStopDictation
        ) { [weak self] in
            Task { @MainActor in
                self?.stopRecording()
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

        UserDefaults.standard.set(true, forKey: pipStandbyKey)

        // 激活音频会话 + 开始播放极低音量噪声
        activateBackgroundAudioSession()
        silentPlayer.start()

        // 启动心跳
        startHeartbeat()

        // 通知键盘:准备好了
        DarwinBridge.postNotification(DarwinNotificationName.dictationStarted)

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
        UserDefaults.standard.set(false, forKey: pipStandbyKey)
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
        guard state != .recording else {
            print("[BGDictation] Already recording, ignoring")
            return
        }

        // 如果保活没启用，自动启用
        if !isPipStandbyEnabled {
            print("[BGDictation] Auto-enabling standby on first request")
            isPipStandbyEnabled = true
            UserDefaults.standard.set(true, forKey: pipStandbyKey)
            activateBackgroundAudioSession()
            silentPlayer.start()
            startHeartbeat()
        }

        // 确保 audio session 活着
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)

        // 从命名剪贴板读取设置
        guard let settings = DarwinBridge.readDictationSettings() else {
            DarwinBridge.writeError("设置读取失败", session: UUID().uuidString)
            return
        }

        currentSessionId = settings.session
        currentSettings = settings
        print("[BGDictation] Starting recording, session=\(currentSessionId.prefix(8))")

        // 立即通知键盘:已开始（取消超时 timer，不跳转！）
        DarwinBridge.postNotification(DarwinNotificationName.dictationStarted)

        // 开始录音
        startRecording(settings: settings)
    }

    // MARK: - 录音

    private func startRecording(settings: DictationSettings) {
        recognizedText = ""
        state = .recording

        // ★ 不暂停 silentPlayer！.mixWithOthers 允许同时工作

        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: settings.language))

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            DarwinBridge.writeError("语音识别不可用,请检查网络", session: currentSessionId)
            state = .idle
            return
        }

        let engine = AVAudioEngine()
        audioEngine = engine

        do {
            let session = AVAudioSession.sharedInstance()
            // ★ 不改变 category options！和待命模式完全一致
            // 只改 mode（whisper 用 .voiceChat 提升语音质量）
            // 避免 setCategory 导致 silent player 被中断
            if settings.whisper {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers])
            } else {
                try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers])
            }
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let req = recognitionRequest else { return }
            req.shouldReportPartialResults = true
            req.requiresOnDeviceRecognition = false

            recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
                Task { @MainActor in
                    guard let self = self else { return }
                    if let result = result {
                        let text = result.bestTranscription.formattedString
                        self.recognizedText = text
                        self.lastTextUpdateTime = CFAbsoluteTimeGetCurrent()
                    }
                    if let error = error as? NSError, error.code != 203 {
                        self.stopRecording()
                    }
                    if result?.isFinal == true {
                        self.stopRecording()
                    }
                }
            }

            let inputNode = engine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                req.append(buffer)
            }

            engine.prepare()
            try engine.start()

            lastTextUpdateTime = CFAbsoluteTimeGetCurrent()
            startSilenceTimer()

            print("[BGDictation] Recording started")

        } catch {
            print("[BGDictation] Failed to start: \(error.localizedDescription)")
            DarwinBridge.writeError("启动录音失败", session: currentSessionId)
            state = .idle
            cleanupAudio()
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

        DarwinBridge.postNotification(DarwinNotificationName.dictationStopped)

        if resultText.isEmpty {
            DarwinBridge.writeError("未识别到语音", session: currentSessionId)
            finishRecording()
        } else {
            let selectedText = settings?.selectedText
            let keyboardType = settings?.keyboardType ?? 0
            let hadSelectedText = selectedText != nil && !(selectedText?.isEmpty ?? true)

            Task { [weak self] in
                guard let self = self else { return }
                let processed = await TextProcessor.shared.process(
                    resultText,
                    selectedText: selectedText,
                    keyboardType: keyboardType
                )

                let finalText = processed.isEmpty ? resultText : processed
                DarwinBridge.writeTranscription(
                    finalText,
                    session: self.currentSessionId,
                    deleteSelected: hadSelectedText && TextProcessor.shared.voiceEditEnabled
                )
                self.finishRecording()
            }
        }

        print("[BGDictation] Recording stopped, result: \(resultText.count) chars")
    }

    private func finishRecording() {
        // ★ 立即恢复，不要 2 秒延迟！
        // 延迟期间没有音频活动，iOS 会挂起 App
        state = .idle
        cleanupAudio()

        // 重置 audio session 为后台保活模式
        activateBackgroundAudioSession()
        silentPlayer.resume()

        print("[BGDictation] Finished, back to standby immediately")
    }

    // MARK: - 静音自动停止

    private func startSilenceTimer() {
        silenceTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self = self, self.state == .recording else { return }

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
