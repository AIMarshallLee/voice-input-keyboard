import UIKit
import AVFoundation
import Speech

/// 极简语音输入键盘 - 只有一个大按钮
class KeyboardViewController: UIInputViewController {

    private let micButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)

    private let audioEngine = AVAudioEngine()
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isRecording = false
    private var recognizedText = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) ?? SFSpeechRecognizer()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopRecording()
    }

    // MARK: - UI

    private func setupUI() {
        view.backgroundColor = UIColor.systemBackground

        // 大麦克风按钮 - 占满键盘区域
        micButton.setImage(UIImage(systemName: "mic.fill"), for: .normal)
        micButton.tintColor = .white
        micButton.titleLabel?.font = UIFont.systemFont(ofSize: 48)
        micButton.backgroundColor = UIColor.systemBlue
        micButton.layer.cornerRadius = 48
        micButton.translatesAutoresizingMaskIntoConstraints = false
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        view.addSubview(micButton)

        // 左下角切换键盘按钮(必须有,否则切不回其他键盘)
        globeButton.setTitle("🌐", for: .normal)
        globeButton.titleLabel?.font = UIFont.systemFont(ofSize: 22)
        globeButton.translatesAutoresizingMaskIntoConstraints = false
        globeButton.addTarget(self, action: #selector(globeTapped), for: .touchUpInside)
        view.addSubview(globeButton)

        NSLayoutConstraint.activate([
            micButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            micButton.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -10),
            micButton.widthAnchor.constraint(equalToConstant: 96),
            micButton.heightAnchor.constraint(equalToConstant: 96),

            globeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            globeButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])
    }

    // MARK: - 按钮事件

    @objc private func micTapped() {
        isRecording ? stopRecording() : startRecording()
    }

    @objc private func globeTapped() {
        advanceToNextInputMode()
    }

    // MARK: - 语音识别

    private func startRecording() {
        guard hasFullAccess else {
            micButton.setTitle("需开启完全访问", for: .normal)
            micButton.titleLabel?.font = UIFont.systemFont(ofSize: 14)
            return
        }

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard status == .authorized else { return }
                self?.beginRecording()
            }
        }
    }

    private func beginRecording() {
        recognizedText = ""
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let req = recognitionRequest else { return }
            req.shouldReportPartialResults = true
            if #available(iOS 13, *) {
                req.requiresOnDeviceRecognition = speechRecognizer?.supportsOnDeviceRecognition(locale: Locale(identifier: "zh-CN")) ?? false
            }

            recognitionTask = speechRecognizer?.recognitionTask(with: req) { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if let result = result {
                        self.recognizedText = result.bestTranscription.formattedString
                        self.micButton.setTitle(self.recognizedText.isEmpty ? "" : self.recognizedText, for: .normal)
                        self.micButton.titleLabel?.font = UIFont.systemFont(ofSize: 16)
                    }
                    if let error = error as? NSError, error.code != 203 {
                        self.stopRecording()
                    }
                    if result?.isFinal == true { self.stopRecording() }
                }
            }

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in req.append(buf) }
            audioEngine.prepare()
            try audioEngine.start()

            // 切换为录音状态
            isRecording = true
            micButton.setImage(nil, for: .normal)
            micButton.setTitle("聆听中…", for: .normal)
            micButton.titleLabel?.font = UIFont.systemFont(ofSize: 18)
            micButton.backgroundColor = UIColor.systemRed
            micButton.layer.add(makePulse(), forKey: "pulse")

        } catch {
            micButton.setTitle("启动失败", for: .normal)
            cleanup()
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let text = recognizedText
        micButton.layer.removeAnimation(forKey: "pulse")
        micButton.backgroundColor = UIColor.systemBlue
        micButton.setTitle(nil, for: .normal)
        micButton.setImage(UIImage(systemName: "mic.fill"), for: .normal)

        if !text.isEmpty {
            textDocumentProxy.insertText(text)
        }

        cleanup()
    }

    private func cleanup() {
        recognitionRequest = nil
        recognitionTask = nil
        recognizedText = ""
    }

    // 简单脉冲动画
    private func makePulse() -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.duration = 0.7
        a.fromValue = 1.0
        a.toValue = 1.1
        a.autoreverses = true
        a.repeatCount = .infinity
        return a
    }
}
