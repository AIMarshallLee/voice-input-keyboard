import Foundation
import AVFoundation
import Speech
import AVKit
import UIKit

/// 后台语音听写管理器 (Build 17)
///
/// 这是 Typeless / 微信输入法的核心方案:
/// 1. 用户开启"PiP保活"后,App 进入后台待命模式
/// 2. PiP 悬浮窗显示"待命中",App 保持存活
/// 3. 每 2s 发一次心跳,让键盘知道主 App 存活
/// 4. 键盘点麦克风时,如果心跳新鲜,发 Darwin 通知 (Path A,不切 App)
/// 5. 本管理器收到通知,直接在后台开始录音
/// 6. PiP 悬浮窗切换到"正在聆听..."
/// 7. 说完后自动停止,结果写入命名剪贴板,发 Darwin 通知通知键盘
/// 8. 键盘收到通知,读剪贴板,插入文字
/// 9. PiP 回到"待命中",等待下一次触发
///
/// Path B (URL Scheme + DictationView) 仅用于:
/// - 首次使用(用户还没开 PiP 保活)
/// - App 被系统杀掉后重启
@MainActor
class BackgroundDictationManager: ObservableObject {

    static let shared = BackgroundDictationManager()

    // MARK: - 状态

    enum State {
        case idle           // 待命中 (PiP保活中)
        case recording      // 正在录音
        case processing     // 正在处理结果
        case completed      // 完成 (短暂显示后回到 idle)
    }

    @Published private(set) var state: State = .idle
    @Published var isPipStandbyEnabled = false  // PiP保活是否开启

    // UserDefaults key for persisting PiP standby state
    private let pipStandbyKey = "pipStandbyEnabled"

    // MARK: - 录音相关

    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizedText = ""
    private var silenceTimer: DispatchSourceTimer?
    private var lastTextUpdateTime: CFAbsoluteTime = 0

    // 心跳定时器:保活模式下每 2s 发一次
    private var heartbeatTimer: DispatchSourceTimer?

    // ★ 静音音频播放器:持续播放无声音频,让 iOS 认为 App 在"播放音频"
    // 只 setActive 不播放,iOS 会在几十秒后挂起 App → Darwin 通知丢失 → 跳 App
    // 有了这个,App 在后台持续存活,键盘发 Darwin 通知即可直接触发录音
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
    }

    /// App 启动时调用:如果用户之前开启过 PiP 保活,自动恢复
    /// 这样用户只需要开一次,以后每次打开 App 都自动进入待命模式
    func autoRestoreIfNeeded() {
        let saved = UserDefaults.standard.bool(forKey: pipStandbyKey)
        if saved && !isPipStandbyEnabled {
            print("[BGDictation] Auto-restoring PiP standby from UserDefaults")
            enablePipStandby()
        }
    }

    deinit {
        heartbeatTimer?.cancel()
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

    // MARK: - PiP 保活模式

    /// 开启 PiP 保活 (Typeless / 微信输入法核心方案)
    ///
    /// 用户在 App 内开启此开关后:
    /// 1. 立即激活后台音频会话并持续保持 (iOS 认为 App 在"播放音频",不会被杀)
    /// 2. 启动心跳 (每 2s 发一次,让键盘知道 App 存活)
    /// 3. PiP 悬浮窗显示"待命中"
    /// 4. 用户滑回宿主 App 后,PiP 自动弹出
    /// 5. 键盘点麦克风 → Darwin 通知 → 后台直接录音 → 文字插入
    /// 全程不切换 App,和 Typeless / 微信输入法一样
    func enablePipStandby() {
        guard !isPipStandbyEnabled else { return }
        isPipStandbyEnabled = true

        // 持久化:用户只需要开启一次,以后 App 重启后自动恢复
        UserDefaults.standard.set(true, forKey: pipStandbyKey)

        // ★ 关键: 激活音频会话 + 开始播放静音音频
        // 只 setActive 不够! iOS 需要看到"正在播放"才不挂起 App
        // silentPlayer 持续播放无声音频 = iOS 认为 App 在播放 = 进程不被挂起
        activateBackgroundAudioSession()
        silentPlayer.start()

        // 启动心跳
        startHeartbeat()

        // 设置 PiP 为待命状态并尝试启动
        PiPManager.shared.setStandbyMode()
        PiPManager.shared.startPiP()

        // 发送 dictationStarted 让键盘知道我们准备好了
        DarwinBridge.postNotification(DarwinNotificationName.dictationStarted)

        print("[BGDictation] PiP standby enabled, audio session held, heartbeat started")
    }

    /// 激活后台音频会话 (持续保持,不关闭)
    /// 这是 Typeless / 微信输入法保活的核心机制:
    /// - playAndRecord + mixWithOthers: 不打断其他 App 音频
    /// - 持续激活 = iOS 认为 App 在"播放音频" = 进程不被挂起
    /// - 麦克风仅在 startRecording 时才开始采集
    private func activateBackgroundAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            print("[BGDictation] Background audio session activated and held")
        } catch {
            print("[BGDictation] Failed to activate audio session: \(error.localizedDescription)")
        }
    }

    /// 关闭 PiP 保活
    func disablePipStandby() {
        isPipStandbyEnabled = false
        UserDefaults.standard.set(false, forKey: pipStandbyKey)
        stopHeartbeat()
        silentPlayer.stop()

        if state == .recording {
            stopRecording()
        }

        PiPManager.shared.stopPiP()
        state = .idle

        // 延迟关闭 audio session,等 PiP 完全停止
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            print("[BGDictation] Audio session deactivated after PiP stop")
        }

        print("[BGDictation] PiP standby disabled")
    }

    // MARK: - 心跳

    /// 每 2s 发一次心跳 Darwin 通知
    /// 键盘据此判断走 Path A (Darwin) 还是 Path B (URL Scheme)
    private func startHeartbeat() {
        stopHeartbeat()

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        timer.schedule(deadline: .now(), repeating: 2.0)
        timer.setEventHandler { DarwinBridge.writeHeartbeat() }
        timer.resume()
        heartbeatTimer = timer

        // 立即发一次
        DarwinBridge.writeHeartbeat()
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    // MARK: - 处理听写请求 (Path A: Darwin 通知触发)

    private func handleDictationRequest() {
        guard isPipStandbyEnabled else {
            print("[BGDictation] Received request but standby not enabled, ignoring")
            return
        }

        guard state != .recording else {
            print("[BGDictation] Already recording, ignoring duplicate request")
            return
        }

        // ★ 确保 audio session 还活着 (App 可能被系统暂时挂起后恢复)
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)

        // 从命名剪贴板读取设置
        guard let settings = DarwinBridge.readDictationSettings() else {
            print("[BGDictation] No settings in clipboard, cannot start")
            DarwinBridge.writeError("设置读取失败", session: UUID().uuidString)
            return
        }

        currentSessionId = settings.session
        currentSettings = settings
        print("[BGDictation] Path A: starting recording, session=\(currentSessionId.prefix(8))")

        // 通知键盘:已开始
        DarwinBridge.postNotification(DarwinNotificationName.dictationStarted)

        // 开始录音
        startRecording(settings: settings)
    }

    // MARK: - 录音

    private func startRecording(settings: DictationSettings) {
        recognizedText = ""
        state = .recording

        // 暂停静音播放器,释放麦克风给 AVAudioEngine
        silentPlayer.pause()

        // 更新 PiP 显示 + 确保 PiP 在运行
        PiPManager.shared.setRecordingMode()
        PiPManager.shared.startPiP()

        // 配置语音识别器
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: settings.language))

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            DarwinBridge.writeError("语音识别不可用,请检查网络", session: currentSessionId)
            state = .idle
            PiPManager.shared.setStandbyMode()
            return
        }

        let engine = AVAudioEngine()
        audioEngine = engine

        do {
            let session = AVAudioSession.sharedInstance()
            if settings.whisper {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.duckOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers])
            } else {
                try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers])
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
                        PiPManager.shared.updateLiveText(text)
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

            // 继续发心跳 (录音时也发,让键盘知道我们还活着)
            // 心跳已经在 startHeartbeat 里持续发送

            print("[BGDictation] Recording started successfully")

        } catch {
            print("[BGDictation] Failed to start recording: \(error.localizedDescription)")
            DarwinBridge.writeError("启动录音失败: \(error.localizedDescription)", session: currentSessionId)
            state = .idle
            PiPManager.shared.setStandbyMode()
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

        // 通知键盘:听写已停止
        DarwinBridge.postNotification(DarwinNotificationName.dictationStopped)

        // PiP 显示处理中
        PiPManager.shared.setCompletedMode(text: resultText)

        if resultText.isEmpty {
            DarwinBridge.writeError("未识别到语音", session: currentSessionId)
            finishRecording()
        } else {
            // 在主 App 中处理文字 (LLM/翻译/格式化/语音编辑)
            // 键盘扩展内存太小,不能跑 LLM,所以处理必须在主 App 完成
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

        print("[BGDictation] Recording stopped, result length: \(resultText.count)")
    }

    private func finishRecording() {
        // 2s 后回到待命
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }

            self.state = .idle
            self.cleanupAudio()

            // 恢复静音播放器,继续后台保活
            self.silentPlayer.resume()

            if self.isPipStandbyEnabled {
                PiPManager.shared.setStandbyMode()
            }
        }
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
                    print("[BGDictation] Silence detected (\(silence)s), auto-stopping")
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
