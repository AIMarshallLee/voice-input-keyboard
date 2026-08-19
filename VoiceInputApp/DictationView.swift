import SwiftUI
import AVFoundation
import Speech

// MARK: - ViewModel

/// 容器 App 语音听写 ViewModel
/// 在主 App 中执行录音和语音识别(键盘扩展无法录音)
@MainActor
class DictationViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var liveText = ""
    @Published var statusMessage = "准备中..."
    @Published var hasResult = false
    @Published var permissionError: String?
    @Published var selectedTextPreview: String?

    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizedText = ""

    private var languageID = "zh-CN"
    private var whisperMode = false
    private var selectedText: String?
    private var sessionId = ""

    // MARK: - 加载设置

    func loadSettings() {
        let defaults = DictationConstants.sharedDefaults
        sessionId = defaults?.string(forKey: DictationConstants.sessionIdKey) ?? UUID().uuidString
        languageID = defaults?.string(forKey: DictationConstants.languageKey) ?? "zh-CN"
        whisperMode = defaults?.bool(forKey: DictationConstants.whisperModeKey) ?? false
        selectedText = defaults?.string(forKey: DictationConstants.selectedTextKey)
        selectedTextPreview = selectedText

        // 更新状态为录音中
        defaults?.set(DictationConstants.statusRecording, forKey: DictationConstants.statusKey)

        // 创建语音识别器
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: languageID))
    }

    // MARK: - 权限检查

    func checkPermissions() {
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
                        self.statusMessage = "点击下方按钮开始说话"
                    }
                }
            }
        } else {
            statusMessage = "点击下方按钮开始说话"
        }
    }

    // MARK: - 录音

    func startRecording() {
        recognizedText = ""
        liveText = ""

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            permissionError = "语音识别不可用,请检查网络连接或语言设置"
            return
        }

        let engine = AVAudioEngine()
        audioEngine = engine

        do {
            let session = AVAudioSession.sharedInstance()
            if whisperMode {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.duckOthers, .allowBluetooth])
            } else {
                try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .allowBluetooth])
            }
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let req = recognitionRequest else { return }
            req.shouldReportPartialResults = true
            // 主 App 没有内存限制,可以使用设备端识别
            // 但服务器识别兼容性更好,MVP 阶段先用服务器识别
            req.requiresOnDeviceRecognition = false

            recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if let result = result {
                        let text = result.bestTranscription.formattedString
                        self.recognizedText = text
                        self.liveText = text
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

        } catch {
            statusMessage = "启动失败: \(error.localizedDescription)"
            cleanup()
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let defaults = DictationConstants.sharedDefaults
        let resultText = recognizedText

        if resultText.isEmpty {
            defaults?.set(DictationConstants.statusError, forKey: DictationConstants.statusKey)
            defaults?.set("未识别到语音", forKey: DictationConstants.errorMessageKey)
            statusMessage = "未识别到语音"
        } else {
            defaults?.set(resultText, forKey: DictationConstants.resultKey)
            defaults?.set(DictationConstants.statusCompleted, forKey: DictationConstants.statusKey)
        }

        hasResult = true

        // 发送 Darwin 通知,通知键盘扩展读取结果
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotificationCenter(),
            CFNotificationName(DictationConstants.darwinNotificationName),
            nil, nil, true
        )
    }

    func cleanup() {
        if isRecording {
            // 录音被中断,标记为错误
            let defaults = DictationConstants.sharedDefaults
            defaults?.set(DictationConstants.statusError, forKey: DictationConstants.statusKey)
            defaults?.set("已取消", forKey: DictationConstants.errorMessageKey)

            audioEngine?.stop()
            audioEngine?.inputNode.removeTap(onBus: 0)
            isRecording = false

            // 发送通知让键盘知道已取消
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotificationCenter(),
                CFNotificationName(DictationConstants.darwinNotificationName),
                nil, nil, true
            )
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        audioEngine = nil
    }
}

// MARK: - View

/// 容器 App 的语音听写页面
/// 由键盘扩展通过 URL Scheme (votype://dictation) 触发
struct DictationView: View {
    @StateObject private var viewModel = DictationViewModel()
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // 顶部:图标和状态
            VStack(spacing: 12) {
                Image(systemName: viewModel.hasResult ? "checkmark.circle.fill" : (viewModel.isRecording ? "waveform.circle.fill" : "mic.circle.fill"))
                    .font(.system(size: 72))
                    .foregroundColor(viewModel.hasResult ? .green : (viewModel.isRecording ? .red : .blue))

                Text(viewModel.hasResult ? "识别完成" : (viewModel.isRecording ? "正在聆听..." : "语音输入"))
                    .font(.title.bold())

                if !viewModel.hasResult && !viewModel.isRecording {
                    Text(viewModel.statusMessage)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, 20)

            // 中间:实时识别文本
            ScrollView {
                if viewModel.liveText.isEmpty {
                    Text(viewModel.isRecording ? "等待说话..." : "识别结果将显示在这里")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text(viewModel.liveText)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            .frame(maxHeight: .infinity)

            // 选中文字提示(语音编辑模式)
            if let preview = viewModel.selectedTextPreview, !preview.isEmpty, !viewModel.hasResult {
                Text("编辑模式: 选中「\(preview.prefix(20))...」")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.horizontal)
            }

            // 错误提示
            if let error = viewModel.permissionError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding()
            }

            Spacer()

            // 底部:操作按钮
            VStack(spacing: 16) {
                if viewModel.hasResult {
                    VStack(spacing: 8) {
                        Text("请返回之前的App,文字将自动插入")
                            .font(.subheadline)
                            .foregroundColor(.blue)

                        Button("完成") {
                            viewModel.cleanup()
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
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
                    Button(action: { viewModel.startRecording() }) {
                        Label("开始语音输入", systemImage: "mic.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.horizontal)
                }

                if !viewModel.hasResult && !viewModel.isRecording {
                    Button("取消") {
                        viewModel.cleanup()
                        dismiss()
                    }
                    .foregroundColor(.secondary)
                }
            }
            .padding(.bottom, 40)
        }
        .padding()
        .onAppear {
            viewModel.loadSettings()
            viewModel.checkPermissions()
        }
        .onDisappear {
            viewModel.cleanup()
        }
    }
}
