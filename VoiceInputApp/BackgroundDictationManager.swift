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

    // Darwin 通知监听
    private var startDictationObserver: DarwinNotificationObserver?
    private var stopDictationObserver: DarwinNotificationObserver?

    // 当前会话
    private var currentSessionId = ""

    // MARK: - 初始化

    private init() {
        setupDarwinObservers()
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

    /// 开启 PiP 保活
    /// App 进入后台,PiP 显示"待命中",每 2s 发心跳
    func enablePipStandby() {
        guard !isPipStandbyEnabled else { return }
        isPipStandbyEnabled = true

        // 启动心跳
        startHeartbeat()

        // 设置 PiP 为待命状态
        PiPManager.shared.setStandbyMode()

        // 发送 dictationStarted 让键盘知道我们准备好了
        DarwinBridge.postNotification(DarwinNotificationName.dictationStarted)

        print("[BGDictation] PiP standby enabled, heartbeat started")
    }

    /// 关闭 PiP 保活
    func disablePipStandby() {
        isPipStandbyEnabled = false
        stopHeartbeat()

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

        // 从命名剪贴板读取设置
        guard let settings = DarwinBridge.readDictationSettings() else {
            print("[BGDictation] No settings in clipboard, cannot start")
            DarwinBridge.writeError("设置读取失败", session: UUID().uuidString)
            return
        }

        currentSessionId = settings.session
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

        // 更新 PiP 显示
        PiPManager.shared.setRecordingMode()

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
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.duckOthers, .allowBluetooth, .allowBluetoothA2DP, .mixWithOthers])
            } else {
                try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .allowBluetooth, .allowBluetoothA2DP, .mixWithOthers])
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

        if resultText.isEmpty {
            DarwinBridge.writeError("未识别到语音", session: currentSessionId)
        } else {
            DarwinBridge.writeTranscription(resultText, session: currentSessionId)
        }

        // 通知键盘:听写已停止
        DarwinBridge.postNotification(DarwinNotificationName.dictationStopped)

        // PiP 显示完成状态
        PiPManager.shared.setCompletedMode(text: resultText)

        // 2s 后回到待命
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }

            // ★ 不关闭 audio session!PiP 保活需要 session 保持 active
            // 只清理录音资源
            self.state = .idle
            self.cleanupAudio()

            if self.isPipStandbyEnabled {
                // 回到待命状态,等待下一次触发
                PiPManager.shared.setStandbyMode()
                // 心跳一直在跑,不需要重启
            }
        }

        print("[BGDictation] Recording stopped, result length: \(resultText.count)")
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
