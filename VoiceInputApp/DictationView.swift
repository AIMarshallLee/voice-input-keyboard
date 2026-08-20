import SwiftUI
import AVFoundation
import Speech

// MARK: - ViewModel

/// 容器 App 语音听写 ViewModel
/// 仅首次使用时显示 (URL Scheme 降级路径)
/// 录音完成后自动启用 BackgroundDictationManager 后台保活
/// 之后不再显示此页面
@MainActor
class DictationViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var liveText = ""
    @Published var statusMessage = "准备中..."
    @Published var hasResult = false
    @Published var permissionError: String?

    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizedText = ""
    private var silenceTimer: Timer?
    private var lastTextUpdateTime: Date?

    // 心跳定时器:每 0.5s 写一次心跳,让键盘知道主 App 存活
    private var heartbeatTimer: DispatchSourceTimer?

    private var languageID = "zh-CN"
    private var whisperMode = false
    private var selectedText: String?
    private var sessionId = ""
    private var keyboardType: Int = 0

    // MARK: - 从 URL 加载设置

    func loadSettings(from url: URL?) {
        // Path B: URL Scheme 传参
        if let url = url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let queryItems = components.queryItems ?? []
            let dict = Dictionary(queryItems.compactMap { item -> (String, String)? in
                guard let value = item.value else { return nil }
                return (item.name, value)
            }, uniquingKeysWith: { _, last in last })

            sessionId = dict[DictationConstants.paramSession] ?? UUID().uuidString
            languageID = dict[DictationConstants.paramLang] ?? "zh-CN"
            whisperMode = dict[DictationConstants.paramWhisper] == "1"
            selectedText = dict[DictationConstants.paramSelectedText]
            keyboardType = Int(dict[DictationConstants.paramKbType] ?? "0") ?? 0
        } else if let settings = DarwinBridge.readDictationSettings() {
            // Path A: Darwin 通知触发,设置从命名剪贴板读取
            sessionId = settings.session
            languageID = settings.language
            whisperMode = settings.whisper
            selectedText = settings.selectedText
            keyboardType = settings.keyboardType
            print("[Dictation] Loaded settings from clipboard (Path A), session=\(sessionId.prefix(8))")
        } else {
            sessionId = UUID().uuidString
            languageID = "zh-CN"
        }

        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: languageID))
    }

    // MARK: - 权限检查 + 自动开始录音

    func checkPermissionsAndStart() {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()

        if speechStatus != .authorized {
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    if status != .authorized {
                        self.permissionError = "请到设置中允许语音识别权限"
                    } else {
                        self.checkMicPermission()
                    }
                }
            }
        } else {
            checkMicPermission()
        }
    }

    private func checkMicPermission() {
        let micStatus = AVAudioSession.sharedInstance().recordPermission
        if micStatus != .granted {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if !granted {
                        self.permissionError = "请到设置中允许麦克风权限"
                    } else {
                        self.startRecording()
                    }
                }
            }
        } else {
            startRecording()
        }
    }

    // MARK: - 录音

    func startRecording() {
        recognizedText = ""
        liveText = ""

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            permissionError = "语音识别不可用,请检查网络连接"
            return
        }

        let engine = AVAudioEngine()
        audioEngine = engine

        do {
            let session = AVAudioSession.sharedInstance()
            // ★ 不使用 .duckOthers！和后台保活模式一致
            // .duckOthers 会让 iOS 认为这个 session 是"次要"的，更容易被挂起
            if whisperMode {
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
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if let result = result {
                        let text = result.bestTranscription.formattedString
                        self.recognizedText = text
                        self.liveText = text
                        self.lastTextUpdateTime = Date()
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

            isRecording = true
            statusMessage = "正在聆听..."
            lastTextUpdateTime = Date()
            startSilenceTimer()

            // 写入心跳 + 发送 dictationStarted 通知 (键盘收到后取消 5s 超时)
            DarwinBridge.writeHeartbeat()
            DarwinBridge.postNotification(DarwinNotificationName.dictationStarted)
            startHeartbeat()

        } catch {
            statusMessage = "启动失败: \(error.localizedDescription)"
            cleanup()
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false

        silenceTimer?.invalidate()
        silenceTimer = nil

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        let resultText = recognizedText
        let hadSelectedText = selectedText != nil && !(selectedText?.isEmpty ?? true)
        let kbType = keyboardType

        // 通知键盘:听写已停止
        DarwinBridge.postNotification(DarwinNotificationName.dictationStopped)

        if resultText.isEmpty {
            DarwinBridge.writeError("未识别到语音", session: sessionId)
            statusMessage = "未识别到语音"
            hasResult = true
            transitionToStandby()
        } else {
            statusMessage = "正在处理文字..."
            hasResult = true

            // ★ 关键: 不依赖 self! DictationView 会在 2.5s 后 dismiss,
            // viewModel 可能被释放。把所有需要的值捕获为局部变量,
            // 这样即使 viewModel 被释放,Task 也能正常执行
            let capturedSessionId = sessionId
            let capturedSelectedText = selectedText
            let capturedKbType = kbType
            let capturedResultText = resultText
            let capturedHadSelectedText = hadSelectedText

            // 在主 App 中处理文字 (LLM/翻译/格式化/语音编辑)
            // 键盘扩展内存太小,不能跑 LLM
            Task { [weak self] in
                let processed = await TextProcessor.shared.process(
                    capturedResultText,
                    selectedText: capturedSelectedText,
                    keyboardType: capturedKbType
                )

                let finalText = processed.isEmpty ? capturedResultText : processed
                DarwinBridge.writeTranscription(
                    finalText,
                    session: capturedSessionId,
                    deleteSelected: capturedHadSelectedText && TextProcessor.shared.voiceEditEnabled
                )

                // 回到主线程更新 UI (如果 viewModel 还活着)
                await MainActor.run {
                    self?.statusMessage = "识别完成 ✓"
                    self?.transitionToStandby()
                }
            }
        }

        print("[Dictation] Recording stopped, transitioning to standby mode")
    }

    private func transitionToStandby() {
        // ★ 启用后台保活，不使用 PiP
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }

            // 停掉 ViewModel 自己的心跳,BG manager 会接管
            self.stopHeartbeat()

            // 启用后台待命
            BackgroundDictationManager.shared.enablePipStandby()

            // 清理录音资源但保留 audio session
            self.cleanupAudioOnly()
        }
    }

    /// 只清理录音资源,保留 audio session
    private func cleanupAudioOnly() {
        recognitionRequest = nil
        recognitionTask = nil
        audioEngine = nil
        // 不调 AVAudioSession.setActive(false) - 保活需要 session 保持 active
        print("[Dictation] Audio resources cleaned, session kept active for standby")
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
        if isRecording {
            DarwinBridge.writeError("已取消", session: sessionId)
            stopRecording()
        }
        stopHeartbeat()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        audioEngine = nil
    }

    // MARK: - 心跳定时器

    /// 每 0.5s 发一次心跳 Darwin 通知
    /// 键盘扩展通过心跳判断主 App 是否存活,决定走 Path A (Darwin) 还是 Path B (URL)
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
/// 仅首次使用时由 URL Scheme 触发显示
/// 录音完成后自动启用后台保活,之后不再显示
struct DictationView: View {
    @StateObject private var viewModel = DictationViewModel()
    @Environment(\.dismiss) var dismiss
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
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding()
                }

                Spacer()

                // 底部操作按钮
                VStack(spacing: 16) {
                    if viewModel.hasResult {
                        Text("文字已就绪,返回键盘即可\n后台保活已自动开启")
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
            viewModel.loadSettings(from: url)
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
    }
}
