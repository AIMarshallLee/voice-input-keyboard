import SwiftUI
import AVFoundation
import Speech
import AVKit

// MARK: - PiP 容器视图 (UIViewRepresentable)

/// 桥接 UIKit view 给 PiPManager
/// AVSampleBufferDisplayLayer 必须挂载在一个有 window 的 UIView 上
struct PiPContainerView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        // 延迟 setup 确保 view 已经有 window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            PiPManager.shared.setup(in: view)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - ViewModel

/// 容器 App 语音听写 ViewModel
/// 在主 App 中执行录音和语音识别(键盘扩展无法录音)
/// 通过 PiP 悬浮窗让 App 在后台保活,用户可以滑回宿主 App 继续看微信
/// 这是 Typeless 和微信输入法使用的同款方案
@MainActor
class DictationViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var liveText = ""
    @Published var statusMessage = "准备中..."
    @Published var hasResult = false
    @Published var permissionError: String?
    @Published var isPiPActive = false

    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizedText = ""
    private var silenceTimer: Timer?
    private var lastTextUpdateTime: Date?

    private var languageID = "zh-CN"
    private var whisperMode = false
    private var selectedText: String?
    private var sessionId = ""

    // MARK: - 从 URL 加载设置

    func loadSettings(from url: URL?) {
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

    // MARK: - 录音 + PiP

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
            // playAndRecord + mixWithOthers: 录音同时不打断其他 App 的音频
            // 这是 PiP 后台保活的关键配置
            if whisperMode {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.duckOthers, .allowBluetooth, .mixWithOthers])
            } else {
                try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .allowBluetooth, .mixWithOthers])
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
                        // 同步更新 PiP 悬浮窗显示的文字
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

            isRecording = true
            statusMessage = "正在聆听...可以滑回之前的App"
            lastTextUpdateTime = Date()
            startSilenceTimer()

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

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let resultText = recognizedText

        if resultText.isEmpty {
            DictationConstants.writeError(message: "未识别到语音", session: sessionId)
            statusMessage = "未识别到语音"
        } else {
            DictationConstants.writeResult(text: resultText, session: sessionId)
            statusMessage = "识别完成 ✓"
        }

        hasResult = true

        // 停止 PiP 悬浮窗
        PiPManager.shared.stopPiP()
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

    private func resetSilenceTimer() {
        // Timer 会自动继续触发,不需要重启
    }

    // MARK: - 清理

    func cleanup() {
        if isRecording {
            DictationConstants.writeError(message: "已取消", session: sessionId)
            stopRecording()
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        audioEngine = nil
        PiPManager.shared.cleanup()
    }
}

// MARK: - View

/// 容器 App 的语音听写页面
/// 由键盘扩展通过 URL Scheme (votype://dictation?lang=zh-CN&...) 触发
/// 打开后自动开始录音 + 进入 PiP 模式,用户可以滑回宿主 App
/// 悬浮窗会显示录音状态 + 实时识别文本,和 Typeless / 微信输入法体验一致
struct DictationView: View {
    @StateObject private var viewModel = DictationViewModel()
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) var scenePhase
    var url: URL?

    var body: some View {
        ZStack {
            // PiP 容器层 (必须在最底层,用于 AVSampleBufferDisplayLayer)
            PiPContainerView()
                .ignoresSafeArea()

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
                        Text("请返回键盘,文字已就绪")
                            .font(.subheadline)
                            .foregroundColor(.blue)

                        Button("完成") {
                            viewModel.cleanup()
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

                        Text("💡 可以向上滑回微信,录音会在悬浮窗中继续")
                            .font(.caption)
                            .foregroundColor(.gray)
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
            // 延迟 0.2s 确保 PiPContainerView 的 makeUIView 已执行
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                viewModel.checkPermissionsAndStart()
            }
        }
        .onChange(of: viewModel.isRecording) { isRecording in
            if isRecording {
                // 录音开始后,启动 PiP 悬浮窗
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    PiPManager.shared.startPiP()
                }
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background && viewModel.isRecording {
                // App 进入后台,PiP 应该已经启动
                // 确保 PiP 仍在运行
                if !PiPManager.shared.isPiPActive {
                    PiPManager.shared.startPiP()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pipDidRestore)) { _ in
            // 用户点击了 PiP 的还原按钮,回到全屏 App
        }
        .onDisappear {
            viewModel.cleanup()
        }
    }
}
