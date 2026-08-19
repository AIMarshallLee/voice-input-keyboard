import SwiftUI
import AVFoundation
import Speech

// MARK: - ViewModel

/// 容器 App 语音听写 ViewModel
/// 在主 App 中执行录音和语音识别(键盘扩展无法录音)
/// 通过 URL 参数接收设置,通过命名剪贴板返回结果
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

    // MARK: - 从 URL 加载设置

    func loadSettings(from url: URL?) {
        // 从 URL 参数解析设置
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
            selectedTextPreview = selectedText
        } else {
            sessionId = UUID().uuidString
            languageID = "zh-CN"
        }

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

        let resultText = recognizedText

        if resultText.isEmpty {
            // 写入错误到命名剪贴板
            DictationConstants.writeError(message: "未识别到语音", session: sessionId)
            statusMessage = "未识别到语音"
        } else {
            // 写入结果到命名剪贴板
            DictationConstants.writeResult(text: resultText, session: sessionId)
        }

        hasResult = true
    }

    func cleanup() {
        if isRecording {
            // 录音被中断,标记为错误
            DictationConstants.writeError(message: "已取消", session: sessionId)

            audioEngine?.stop()
            audioEngine?.inputNode.removeTap(onBus: 0)
            isRecording = false
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
/// 由键盘扩展通过 URL Scheme (votype://dictation?lang=zh-CN&...) 触发
struct DictationView: View {
    @StateObject private var viewModel = DictationViewModel()
    @Environment(\.dismiss) var dismiss
    var url: URL?

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
            viewModel.loadSettings(from: url)
            viewModel.checkPermissions()
        }
        .onDisappear {
            viewModel.cleanup()
        }
    }
}
