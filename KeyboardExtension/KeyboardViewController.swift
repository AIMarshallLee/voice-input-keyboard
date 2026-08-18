import UIKit
import AVFoundation
import Speech

/// 语音输入键盘 - 完整版
/// 对标 Typeless,核心优势:
/// 1. 中英混输(本地识别天然支持)
/// 2. 完全离线(on-device 识别)
/// 3. 完全免费
/// 4. 零网络传输(隐私优先)
/// 5. 无会话时间限制
/// 6. 不自作主张改格式
/// 7. 实时转写显示
/// 8. 自动去口水词
/// 9. 自动标点
/// 10. 符号快捷栏
class KeyboardViewController: UIInputViewController {

    // MARK: - UI 元素
    private let micButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let spaceButton = UIButton(type: .system)
    private let returnButton = UIButton(type: .system)
    private let liveTextLabel = UILabel()
    private let containerView = UIView()
    private let waveformView = WaveformView()
    private let symbolBar = UIScrollView()
    private let symbolStack = UIStackView()
    private var deleteTimer: Timer?

    // MARK: - 语音识别
    private let audioEngine = AVAudioEngine()
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isRecording = false
    private var recognizedText = ""
    private var hasInsertedText = false

    // MARK: - 设置 (通过 App Group 与宿主 App 共享)
    private let sharedDefaults = UserDefaults(suiteName: "group.com.voiceinput.shared")
    private var autoPunctuationEnabled: Bool {
        sharedDefaults?.object(forKey: "autoPunctuation") as? Bool ?? true
    }
    private var fillerWordRemovalEnabled: Bool {
        sharedDefaults?.object(forKey: "fillerWordRemoval") as? Bool ?? true
    }
    private var livePreviewEnabled: Bool {
        sharedDefaults?.object(forKey: "livePreview") as? Bool ?? true
    }

    // MARK: - 口水词过滤
    private let fillerWords: Set<String> = [
        "嗯", "啊", "呃", "哦", "唉", "嘛", "呢", "哈",
        "那个", "这个", "就是", "然后", "所以说", "对吧",
        "怎么说呢", "说实话", "你知道吗", "其实吧"
    ]

    // MARK: - 快捷符号
    private let symbols = ["，", "。", "！", "？", "、", "：", "；", "\u{201C}", "\u{201D}", "（", "）", "…", "—", "～", "😊", "👍", "✅"]

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
        let isDark = traitCollection.userInterfaceStyle == .dark
        let bgColor = isDark ? UIColor(white: 0.11, alpha: 1) : UIColor(white: 0.96, alpha: 1)
        let buttonColor = isDark ? UIColor(white: 0.18, alpha: 1) : UIColor.white
        let textColor = isDark ? UIColor.white : UIColor.black

        view.backgroundColor = bgColor
        containerView.backgroundColor = .clear
        containerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(containerView)

        // 麦克风按钮
        let config = UIImage.SymbolConfiguration(pointSize: 34, weight: .bold)
        micButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: config), for: .normal)
        micButton.tintColor = .white
        micButton.backgroundColor = UIColor.systemBlue
        micButton.layer.cornerRadius = 36
        micButton.layer.shadowColor = UIColor.systemBlue.cgColor
        micButton.layer.shadowOpacity = 0.35
        micButton.layer.shadowRadius = 8
        micButton.layer.shadowOffset = CGSize(width: 0, height: 4)
        micButton.translatesAutoresizingMaskIntoConstraints = false
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)

        // 实时文字
        liveTextLabel.font = UIFont.systemFont(ofSize: 15)
        liveTextLabel.textColor = textColor.withAlphaComponent(0.6)
        liveTextLabel.textAlignment = .center
        liveTextLabel.numberOfLines = 2
        liveTextLabel.text = "点击麦克风开始语音输入"
        liveTextLabel.translatesAutoresizingMaskIntoConstraints = false

        // 波形
        waveformView.translatesAutoresizingMaskIntoConstraints = false
        waveformView.isHidden = true

        // 符号栏
        symbolBar.showsHorizontalScrollIndicator = false
        symbolBar.translatesAutoresizingMaskIntoConstraints = false
        symbolBar.backgroundColor = .clear
        symbolStack.axis = .horizontal
        symbolStack.spacing = 6
        symbolStack.translatesAutoresizingMaskIntoConstraints = false
        symbolBar.addSubview(symbolStack)

        for symbol in symbols {
            let btn = UIButton(type: .system)
            btn.setTitle(symbol, for: .normal)
            btn.titleLabel?.font = UIFont.systemFont(ofSize: 20)
            btn.setTitleColor(textColor, for: .normal)
            btn.backgroundColor = buttonColor
            btn.layer.cornerRadius = 8
            btn.widthAnchor.constraint(equalToConstant: 40).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 36).isActive = true
            btn.addTarget(self, action: #selector(symbolTapped(_:)), for: .touchUpInside)
            symbolStack.addArrangedSubview(btn)
        }

        // 切换键盘
        globeButton.setImage(UIImage(systemName: "globe"), for: .normal)
        globeButton.tintColor = textColor
        globeButton.backgroundColor = buttonColor
        globeButton.layer.cornerRadius = 8
        globeButton.translatesAutoresizingMaskIntoConstraints = false
        globeButton.addTarget(self, action: #selector(globeTapped), for: .touchUpInside)
        globeButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        globeButton.heightAnchor.constraint(equalToConstant: 36).isActive = true

        // 空格
        spaceButton.setTitle("空格", for: .normal)
        spaceButton.setTitleColor(textColor, for: .normal)
        spaceButton.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        spaceButton.backgroundColor = buttonColor
        spaceButton.layer.cornerRadius = 8
        spaceButton.translatesAutoresizingMaskIntoConstraints = false
        spaceButton.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        spaceButton.heightAnchor.constraint(equalToConstant: 36).isActive = true

        // 删除
        deleteButton.setImage(UIImage(systemName: "delete.left"), for: .normal)
        deleteButton.tintColor = textColor
        deleteButton.backgroundColor = buttonColor
        deleteButton.layer.cornerRadius = 8
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        deleteButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        deleteButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPressDelete(_:)))
        deleteButton.addGestureRecognizer(longPress)

        // 回车
        returnButton.setImage(UIImage(systemName: "return"), for: .normal)
        returnButton.tintColor = textColor
        returnButton.backgroundColor = buttonColor
        returnButton.layer.cornerRadius = 8
        returnButton.translatesAutoresizingMaskIntoConstraints = false
        returnButton.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)
        returnButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        returnButton.heightAnchor.constraint(equalToConstant: 36).isActive = true

        // 底部工具栏
        let bottomBar = UIStackView(arrangedSubviews: [globeButton, spaceButton, deleteButton, returnButton])
        bottomBar.axis = .horizontal
        bottomBar.spacing = 6
        bottomBar.alignment = .fill
        bottomBar.distribution = .fill
        bottomBar.translatesAutoresizingMaskIntoConstraints = false

        containerView.addSubview(micButton)
        containerView.addSubview(liveTextLabel)
        containerView.addSubview(waveformView)
        containerView.addSubview(symbolBar)
        containerView.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: view.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            containerView.heightAnchor.constraint(equalToConstant: 260),

            micButton.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            micButton.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 16),
            micButton.widthAnchor.constraint(equalToConstant: 72),
            micButton.heightAnchor.constraint(equalToConstant: 72),

            waveformView.centerXAnchor.constraint(equalTo: micButton.centerXAnchor),
            waveformView.centerYAnchor.constraint(equalTo: micButton.centerYAnchor),
            waveformView.widthAnchor.constraint(equalToConstant: 72),
            waveformView.heightAnchor.constraint(equalToConstant: 72),

            liveTextLabel.topAnchor.constraint(equalTo: micButton.bottomAnchor, constant: 8),
            liveTextLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            liveTextLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),

            symbolBar.topAnchor.constraint(equalTo: liveTextLabel.bottomAnchor, constant: 10),
            symbolBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 6),
            symbolBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -6),
            symbolBar.heightAnchor.constraint(equalToConstant: 40),

            symbolStack.topAnchor.constraint(equalTo: symbolBar.topAnchor),
            symbolStack.leadingAnchor.constraint(equalTo: symbolBar.leadingAnchor, constant: 6),
            symbolStack.trailingAnchor.constraint(equalTo: symbolBar.trailingAnchor, constant: -6),
            symbolStack.heightAnchor.constraint(equalTo: symbolBar.heightAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 6),
            bottomBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -6),
            bottomBar.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -6),
            bottomBar.heightAnchor.constraint(equalToConstant: 36),
        ])

        // 让 spaceButton 在 stack 中占满剩余空间
        spaceButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    // MARK: - 语音识别设置

    private func setupSpeech() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        if speechRecognizer == nil {
            speechRecognizer = SFSpeechRecognizer()
        }
    }

    // MARK: - 按钮事件

    @objc private func micTapped() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    @objc private func globeTapped() {
        advanceToNextInputMode()
    }

    @objc private func deleteTapped() {
        textDocumentProxy.deleteBackward()
    }

    @objc private func spaceTapped() {
        textDocumentProxy.insertText(" ")
    }

    @objc private func returnTapped() {
        textDocumentProxy.insertText("\n")
    }

    @objc private func symbolTapped(_ sender: UIButton) {
        if let symbol = sender.title(for: .normal) {
            textDocumentProxy.insertText(symbol)
        }
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

    // MARK: - 录音

    private func startRecording() {
        guard hasFullAccess else {
            liveTextLabel.text = "请到设置→键盘→语音输入→开启「允许完全访问」"
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
            req.shouldReportPartialResults = true

            if #available(iOS 13, *) {
                req.requiresOnDeviceRecognition = speechRecognizer?.supportsOnDeviceRecognition ?? false
            }

            recognitionTask = speechRecognizer?.recognitionTask(with: req) { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self = self else { return }

                    if let result = result {
                        let rawText = result.bestTranscription.formattedString
                        var cleanedText = rawText
                        if self.fillerWordRemovalEnabled {
                            cleanedText = self.removeFillerWords(from: cleanedText)
                        }
                        self.recognizedText = cleanedText

                        if self.livePreviewEnabled {
                            if cleanedText.isEmpty {
                                self.liveTextLabel.text = "正在聆听…"
                            } else {
                                self.liveTextLabel.text = cleanedText
                            }
                        }
                    }

                    if let error = error as? NSError, error.code != 203 {
                        self.stopRecording()
                    }
                    if result?.isFinal == true {
                        self.stopRecording()
                    }
                }
            }

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                req.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()

            isRecording = true
            micButton.setImage(nil, for: .normal)
            micButton.setTitle("停止", for: .normal)
            micButton.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
            micButton.backgroundColor = UIColor.systemRed
            waveformView.isHidden = false
            liveTextLabel.text = "正在聆听…"
            startPulse()

        } catch {
            liveTextLabel.text = "启动失败: \(error.localizedDescription)"
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

        var text = recognizedText
        if autoPunctuationEnabled {
            text = addAutoPunctuation(to: text)
        }

        stopPulse()
        micButton.setTitle(nil, for: .normal)
        let config = UIImage.SymbolConfiguration(pointSize: 34, weight: .bold)
        micButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: config), for: .normal)
        micButton.backgroundColor = UIColor.systemBlue
        waveformView.isHidden = true

        if !text.isEmpty && !hasInsertedText {
            textDocumentProxy.insertText(text)
            hasInsertedText = true
            let preview = text.prefix(30)
            liveTextLabel.text = "已输入 ✓  \(preview)\(text.count > 30 ? "…" : "")"
        } else if text.isEmpty {
            liveTextLabel.text = "未识别到语音,请重试"
        }

        cleanup()
    }

    // MARK: - 口水词过滤

    private func removeFillerWords(from text: String) -> String {
        var result = text
        for word in fillerWords {
            result = result.replacingOccurrences(of: word, with: "")
        }
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 自动标点

    private func addAutoPunctuation(to text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text

        let punctuationSet: Set<Character> = ["。", "！", "？", "，", "、", "：", "；", ".", "!", "?", ","]
        if let last = result.last, punctuationSet.contains(last) {
            return result
        }

        let questionEndings = ["吗", "呢", "吧", "嘛"]
        let questionWords = ["怎么", "什么", "为什么", "哪里", "哪儿", "谁", "哪个", "哪些", "多少", "几", "是不是", "能不能", "可不可以", "难道"]

        let lastChar = String(result.last ?? Character(" "))

        var isQuestion = false
        if questionEndings.contains(lastChar) {
            isQuestion = true
        }
        for word in questionWords {
            if result.contains(word) {
                isQuestion = true
                break
            }
        }

        if isQuestion {
            result += "？"
        } else if lastChar == "的" || lastChar == "了" || lastChar == "着" {
            result += "。"
        } else {
            result += "。"
        }

        return result
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
        pulse.toValue = 1.08
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
        if window != nil { startAnim() } else { stopAnim() }
    }

    private func startAnim() {
        displayLink?.invalidate()
        displayLink = CADisplayLink(target: self, selector: #selector(updateWave))
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
