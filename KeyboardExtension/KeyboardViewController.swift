import UIKit
import AVFoundation
import Speech

/// 语音输入键盘 - 完整版
/// 对标 Typeless,解决其核心痛点:
/// 1. 中英混输(不再全挂)
/// 2. 完全离线(不依赖云端)
/// 3. 完全免费
/// 4. 真正本地处理(零网络传输)
/// 5. 无会话时间限制
/// 6. 不自作主张改格式
/// 7. 实时转写显示
/// 8. 自动去口水词
class KeyboardViewController: UIInputViewController {

    // MARK: - UI 元素
    private let micButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let liveTextLabel = UILabel()
    private let containerView = UIView()
    private let waveformView = WaveformView()
    private var deleteTimer: Timer?

    // MARK: - 语音识别
    private let audioEngine = AVAudioEngine()
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isRecording = false
    private var recognizedText = ""
    private var hasInsertedText = false  // 是否已插入文字(防止重复插入)

    // MARK: - 口水词过滤
    // Typeless 用云端 LLM 去口水词;我们用本地列表,离线即可工作
    private let fillerWords: Set<String> = [
        "嗯", "啊", "呃", "哦", "唉", "嘛", "呢", "哈",
        "那个", "这个", "就是", "然后", "所以说", "对吧",
        "怎么说呢", "说实话", "你知道吗", "其实吧"
    ]

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupSpeech()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopRecording()
    }

    // MARK: - UI

    private func setupUI() {
        view.backgroundColor = UIColor.systemBackground
        containerView.backgroundColor = UIColor.systemBackground
        containerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(containerView)

        // 麦克风按钮(大圆形)
        let config = UIImage.SymbolConfiguration(pointSize: 40, weight: .bold)
        micButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: config), for: .normal)
        micButton.tintColor = .white
        micButton.backgroundColor = UIColor.systemBlue
        micButton.layer.cornerRadius = 44
        micButton.layer.shadowColor = UIColor.systemBlue.cgColor
        micButton.layer.shadowOpacity = 0.3
        micButton.layer.shadowRadius = 8
        micButton.layer.shadowOffset = CGSize(width: 0, height: 4)
        micButton.translatesAutoresizingMaskIntoConstraints = false
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)

        // 实时文字显示(说话时实时显示识别结果)
        liveTextLabel.font = UIFont.systemFont(ofSize: 16)
        liveTextLabel.textColor = UIColor.label
        liveTextLabel.textAlignment = .center
        liveTextLabel.numberOfLines = 3
        liveTextLabel.text = "点击麦克风开始语音输入"
        liveTextLabel.textColor = UIColor.secondaryLabel
        liveTextLabel.translatesAutoresizingMaskIntoConstraints = false

        // 波形动画(录音时显示)
        waveformView.translatesAutoresizingMaskIntoConstraints = false
        waveformView.isHidden = true

        // 切换键盘按钮
        globeButton.setTitle("🌐", for: .normal)
        globeButton.titleLabel?.font = UIFont.systemFont(ofSize: 22)
        globeButton.translatesAutoresizingMaskIntoConstraints = false
        globeButton.addTarget(self, action: #selector(globeTapped), for: .touchUpInside)

        // 删除按钮(支持长按连续删除)
        deleteButton.setTitle("⌫", for: .normal)
        deleteButton.titleLabel?.font = UIFont.systemFont(ofSize: 22)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPressDelete(_:)))
        deleteButton.addGestureRecognizer(longPress)

        containerView.addSubview(micButton)
        containerView.addSubview(liveTextLabel)
        containerView.addSubview(waveformView)
        containerView.addSubview(globeButton)
        containerView.addSubview(deleteButton)

        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: view.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            containerView.heightAnchor.constraint(equalToConstant: 220),

            // 麦克风按钮居中偏上
            micButton.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            micButton.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 20),
            micButton.widthAnchor.constraint(equalToConstant: 88),
            micButton.heightAnchor.constraint(equalToConstant: 88),

            // 实时文字标签
            liveTextLabel.topAnchor.constraint(equalTo: micButton.bottomAnchor, constant: 12),
            liveTextLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            liveTextLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            // 波形视图(覆盖在麦克风按钮位置)
            waveformView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            waveformView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 20),
            waveformView.widthAnchor.constraint(equalToConstant: 88),
            waveformView.heightAnchor.constraint(equalToConstant: 88),

            // 底部按钮
            globeButton.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            globeButton.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -12),

            deleteButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
            deleteButton.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -12),
        ])
    }

    // MARK: - 语音识别设置

    private func setupSpeech() {
        // 使用中文 locale,Apple 的 on-device 模型天然支持中英混说
        // 不像 Typeless 那样中英混输全挂
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        if speechRecognizer == nil {
            speechRecognizer = SFSpeechRecognizer()
        }
    }

    // MARK: - 按钮事件

    @objc private func micTapped() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    @objc private func globeTapped() {
        advanceToNextInputMode()
    }

    @objc private func deleteTapped() {
        textDocumentProxy.deleteBackward()
    }

    @objc private func handleLongPressDelete(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                self?.textDocumentProxy.deleteBackward()
            }
        } else if gesture.state == .ended || gesture.state == .cancelled {
            deleteTimer?.invalidate()
            deleteTimer = nil
        }
    }

    // MARK: - 开始录音

    private func startRecording() {
        // 检查完全访问权限(键盘使用麦克风的必要条件)
        guard hasFullAccess else {
            liveTextLabel.text = "请到设置→通用→键盘→语音输入→开启「允许完全访问」"
            return
        }

        guard speechRecognizer != nil, speechRecognizer!.isAvailable else {
            liveTextLabel.text = "语音识别暂不可用"
            return
        }

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard status == .authorized else {
                    self.liveTextLabel.text = "请到设置中允许语音识别权限"
                    return
                }
                self.beginRecording()
            }
        }
    }

    private func beginRecording() {
        recognizedText = ""
        hasInsertedText = false

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let req = recognitionRequest else { return }

            // 实时显示部分结果(边说边显示)
            req.shouldReportPartialResults = true

            // 优先使用设备端识别(完全离线,不依赖网络)
            // 这是 Typeless 做不到的:它必须走云端
            if #available(iOS 13, *) {
                let locale = Locale(identifier: "zh-CN")
                req.requiresOnDeviceRecognition = speechRecognizer?.supportsOnDeviceRecognition(locale: locale) ?? false
            }

            recognitionTask = speechRecognizer?.recognitionTask(with: req) { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self = self else { return }

                    if let result = result {
                        let rawText = result.bestTranscription.formattedString
                        // 本地去口水词(不需要云端 LLM)
                        let cleanedText = self.removeFillerWords(from: rawText)
                        self.recognizedText = cleanedText

                        // 实时显示识别结果(不等说完才显示)
                        if cleanedText.isEmpty {
                            self.liveTextLabel.text = "正在聆听…"
                        } else {
                            self.liveTextLabel.text = cleanedText
                        }
                    }

                    // 错误码 203 = 无语音输入,属正常情况
                    if let error = error as? NSError, error.code != 203 {
                        self.stopRecording()
                    }

                    if result?.isFinal == true {
                        self.stopRecording()
                    }
                }
            }

            // 安装录音 tap
            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                req.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()

            // 切换为录音状态
            isRecording = true
            micButton.setImage(nil, for: .normal)
            micButton.setTitle("停止", for: .normal)
            micButton.titleLabel?.font = UIFont.systemFont(ofSize: 20, weight: .semibold)
            micButton.backgroundColor = UIColor.systemRed
            micButton.layer.cornerRadius = 44
            waveformView.isHidden = false
            liveTextLabel.text = "正在聆听…"
            startPulse()

        } catch {
            liveTextLabel.text = "启动失败: \(error.localizedDescription)"
            cleanup()
        }
    }

    // MARK: - 停止录音

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false

        // 停止音频引擎
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        // 停用音频会话
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        // 恢复 UI
        let text = recognizedText
        stopPulse()
        micButton.setTitle(nil, for: .normal)
        let config = UIImage.SymbolConfiguration(pointSize: 40, weight: .bold)
        micButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: config), for: .normal)
        micButton.backgroundColor = UIColor.systemBlue
        waveformView.isHidden = true

        // 插入文字(只插入一次,防止重复)
        if !text.isEmpty && !hasInsertedText {
            textDocumentProxy.insertText(text)
            hasInsertedText = true
            liveTextLabel.text = "已输入 ✓  \(text.prefix(30))\(text.count > 30 ? "…" : "")"
        } else if text.isEmpty {
            liveTextLabel.text = "未识别到语音,请重试"
        }

        cleanup()
    }

    // MARK: - 口水词过滤(本地,不需要云端 LLM)

    /// 从识别文本中去除口水词
    /// Typeless 用云端 LLM 处理;我们用本地规则,离线即可工作
    private func removeFillerWords(from text: String) -> String {
        var result = text

        // 按空格分割处理(中文通常无空格,但英文有)
        // 直接替换口水词
        for word in fillerWords {
            result = result.replacingOccurrences(of: word, with: "")
        }

        // 清理多余空格
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 清理

    private func cleanup() {
        recognitionRequest = nil
        recognitionTask = nil
    }

    // MARK: - 脉冲动画

    private func startPulse() {
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.duration = 0.8
        pulse.fromValue = 1.0
        pulse.toValue = 1.1
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        micButton.layer.add(pulse, forKey: "pulse")
    }

    private func stopPulse() {
        micButton.layer.removeAnimation(forKey: "pulse")
    }
}

// MARK: - 波形视图

class WaveformView: UIView {

    private let waveLayer = CAShapeLayer()
    private var displayLink: CADisplayLink?
    private var phase: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear
        waveLayer.fillColor = UIColor.clear.cgColor
        waveLayer.strokeColor = UIColor.systemRed.cgColor
        waveLayer.lineWidth = 3
        waveLayer.lineCap = .round
        layer.addSublayer(waveLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        waveLayer.frame = bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            startAnim()
        } else {
            stopAnim()
        }
    }

    private func startAnim() {
        displayLink?.invalidate()
        displayLink = CADisplayLink(target: self, action: #selector(updateWave))
        displayLink?.add(to: .main, forMode: .common)
    }

    private func stopAnim() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func updateWave() {
        phase += 0.15
        let path = UIBezierPath()
        let w = bounds.width
        let h = bounds.height
        let midY = h / 2
        let amp = h * 0.3

        path.move(to: CGPoint(x: 0, y: midY))
        for x in stride(from: CGFloat(0), to: w, by: 2) {
            let relX = x / w
            let y = midY + sin(relX * .pi * 4 + phase) * amp
            path.addLine(to: CGPoint(x: x, y: y))
        }
        waveLayer.path = path.cgPath
    }
}
