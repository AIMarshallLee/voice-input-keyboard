import UIKit

/// 语音输入键盘 - 容器 App 回调架构
/// iOS 键盘扩展无法直接录音(平台限制)
/// 流程: 键盘点击麦克风 → URL启动容器App → 容器App录音+识别 → 命名剪贴板传回结果 → Darwin通知信号 → 键盘插入文字
class KeyboardViewController: UIInputViewController {

    // MARK: - UI 元素
    private let micButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)
    private let langButton = UIButton(type: .system)
    private let translateButton = UIButton(type: .system)
    private let whisperButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let spaceButton = UIButton(type: .system)
    private let returnButton = UIButton(type: .system)
    private let liveTextLabel = UILabel()
    private let containerView = UIView()
    private let waveformView = WaveformView()
    private let symbolBar = UIScrollView()
    private let symbolStack = UIStackView()
    private var deleteTimer: Timer?

    // MARK: - 容器 App 通信状态
    private var isWaitingForResult = false
    private var currentSessionId: String?

    // 暂存启动时的设置,处理结果时使用
    private var pendingSelectedText: String?
    private var pendingKbType: Int = 0

    // MARK: - 模式状态
    private var isWhisperMode = false
    private var selectedTextBeforeRecording: String?

    // MARK: - 快捷符号
    private let symbols = ["，", "。", "！", "？", "、", "：", "；", "\u{201C}", "\u{201D}", "（", "）", "…", "—", "～", "😊", "👍", "✅"]

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupDarwinNotification()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 同步设置(用户可能在宿主 App 中修改了设置)
        updateTranslateButton()
        updateLangButton()
        // 检查是否有待处理的识别结果(用户从容器 App 返回时)
        processPendingResult()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopPulse()
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

        // 语言切换按钮 (显示当前语言国旗)
        langButton.tintColor = textColor
        langButton.backgroundColor = buttonColor
        langButton.layer.cornerRadius = 8
        langButton.translatesAutoresizingMaskIntoConstraints = false
        langButton.addTarget(self, action: #selector(langTapped), for: .touchUpInside)
        langButton.widthAnchor.constraint(equalToConstant: 50).isActive = true
        langButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        updateLangButton()

        // 翻译按钮
        translateButton.setImage(UIImage(systemName: "translate"), for: .normal)
        translateButton.tintColor = textColor
        translateButton.backgroundColor = buttonColor
        translateButton.layer.cornerRadius = 8
        translateButton.translatesAutoresizingMaskIntoConstraints = false
        translateButton.addTarget(self, action: #selector(translateToggled), for: .touchUpInside)
        translateButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        translateButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        updateTranslateButton()

        // 耳语模式按钮
        whisperButton.setImage(UIImage(systemName: "ear"), for: .normal)
        whisperButton.tintColor = textColor
        whisperButton.backgroundColor = buttonColor
        whisperButton.layer.cornerRadius = 8
        whisperButton.translatesAutoresizingMaskIntoConstraints = false
        whisperButton.addTarget(self, action: #selector(whisperToggled), for: .touchUpInside)
        whisperButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        whisperButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        updateWhisperButton()

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
        let bottomBar = UIStackView(arrangedSubviews: [globeButton, langButton, translateButton, whisperButton, spaceButton, deleteButton, returnButton])
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

    // MARK: - Darwin 通知

    private func setupDarwinNotification() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotificationCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                DispatchQueue.main.async {
                    guard let observer = observer else { return }
                    let vc = Unmanaged<KeyboardViewController>.fromOpaque(observer).takeUnretainedValue()
                    vc.processPendingResult()
                }
            },
            DictationConstants.darwinNotificationName,
            nil,
            .deliverImmediately
        )
    }

    // MARK: - 语言切换

    private func updateLangButton() {
        let lang = LanguageManager.shared.currentLanguage
        let title = "\(lang.flag) \(lang.id.split(separator: "-").first ?? "")"
        langButton.setTitle(title, for: .normal)
        langButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .medium)
    }

    @objc private func langTapped() {
        // 如果翻译模式开启,切换的是翻译目标语言
        if TranslationManager.shared.translationEnabled {
            let newTarget = TranslationManager.shared.cycleTargetLanguage()
            liveTextLabel.text = "翻译目标: \(newTarget.flag) \(newTarget.name)"
            return
        }

        let newLang = LanguageManager.shared.cycleToNextLanguage()
        updateLangButton()
        liveTextLabel.text = "语言切换至: \(newLang.flag) \(newLang.name)"
    }

    // MARK: - 翻译模式

    private func updateTranslateButton() {
        let isOn = TranslationManager.shared.translationEnabled
        translateButton.tintColor = isOn ? .white : nil
        translateButton.backgroundColor = isOn ? UIColor.systemOrange : (traitCollection.userInterfaceStyle == .dark ? UIColor(white: 0.18, alpha: 1) : UIColor.white)

        if isOn {
            let target = LanguageManager.allLanguages.first { $0.id == TranslationManager.shared.targetLanguageID }
            let flag = target?.flag ?? ""
            translateButton.setTitle(flag, for: .normal)
            translateButton.setImage(nil, for: .normal)
            translateButton.titleLabel?.font = UIFont.systemFont(ofSize: 16)
        } else {
            translateButton.setTitle(nil, for: .normal)
            translateButton.setImage(UIImage(systemName: "translate"), for: .normal)
        }
    }

    @objc private func translateToggled() {
        let newState = !TranslationManager.shared.translationEnabled
        TranslationManager.shared.setTranslationEnabled(newState)
        updateTranslateButton()

        if newState {
            let target = LanguageManager.allLanguages.first { $0.id == TranslationManager.shared.targetLanguageID }
            liveTextLabel.text = "翻译模式开启: 说话后自动翻译为\(target?.name ?? "目标语言")"
        } else {
            liveTextLabel.text = "翻译模式关闭"
        }
    }

    // MARK: - 耳语模式

    private func updateWhisperButton() {
        let isDark = traitCollection.userInterfaceStyle == .dark
        whisperButton.tintColor = isWhisperMode ? .white : nil
        whisperButton.backgroundColor = isWhisperMode ? UIColor.systemPurple : (isDark ? UIColor(white: 0.18, alpha: 1) : UIColor.white)
    }

    @objc private func whisperToggled() {
        isWhisperMode.toggle()
        updateWhisperButton()

        if isWhisperMode {
            liveTextLabel.text = "耳语模式开启: 适合安静环境"
        } else {
            liveTextLabel.text = "耳语模式关闭"
        }
    }

    // MARK: - 按钮事件

    @objc private func micTapped() {
        if isWaitingForResult {
            liveTextLabel.text = "正在等待语音结果,请返回之前的App..."
            return
        }
        launchDictation()
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

    // MARK: - 启动容器 App 录音

    private func launchDictation() {
        guard hasFullAccess else {
            liveTextLabel.text = "请到设置→键盘→VoType→开启「允许完全访问」"
            return
        }

        // 生成会话 ID
        let sessionId = UUID().uuidString
        currentSessionId = sessionId

        // 暂存设置,处理结果时使用
        selectedTextBeforeRecording = textDocumentProxy.selectedText
        pendingSelectedText = selectedTextBeforeRecording
        pendingKbType = textDocumentProxy.keyboardType?.rawValue ?? 0

        // 通过 URL 参数传递设置给容器 App
        guard let url = DictationConstants.buildDictationURL(
            language: LanguageManager.shared.currentLanguage.id,
            whisper: isWhisperMode,
            translateEnabled: TranslationManager.shared.translationEnabled,
            translateTarget: TranslationManager.shared.targetLanguageID,
            selectedText: selectedTextBeforeRecording,
            keyboardType: pendingKbType,
            session: sessionId
        ) else {
            liveTextLabel.text = "无法创建语音输入URL"
            return
        }

        // 通过 responder chain 启动容器 App
        var responder: UIResponder? = self
        var launched = false
        while let r = responder {
            if let app = r as? UIApplication {
                app.open(url) { [weak self] success in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        if success {
                            self.isWaitingForResult = true
                            self.liveTextLabel.text = "正在启动语音输入..."
                            self.startPulse()
                        } else {
                            self.liveTextLabel.text = "无法启动语音输入,请确保App已安装"
                        }
                    }
                }
                launched = true
                break
            }
            responder = r.next
        }

        if !launched {
            liveTextLabel.text = "无法启动语音输入"
        }
    }

    // MARK: - 处理识别结果

    /// 检查命名剪贴板中是否有待处理的识别结果
    /// 在 viewWillAppear 和 Darwin 通知回调中调用
    private func processPendingResult() {
        guard isWaitingForResult else { return }

        let result = DictationConstants.readAndConsumeResult()

        if let text = result.text {
            isWaitingForResult = false
            stopPulse()
            micButton.backgroundColor = UIColor.systemBlue
            handleDictationResult(text)
        } else if let error = result.error {
            isWaitingForResult = false
            stopPulse()
            micButton.backgroundColor = UIColor.systemBlue
            liveTextLabel.text = error
        }
    }

    /// 处理识别结果:语音编辑 + 自我纠正 + 口水词 + LLM润色 + 翻译 + 自动格式化 + 自动标点
    private func handleDictationResult(_ rawText: String) {
        if rawText.isEmpty {
            liveTextLabel.text = "未识别到语音,请重试"
            return
        }

        liveTextLabel.text = "正在处理..."
        micButton.backgroundColor = UIColor.systemOrange

        // 使用暂存的设置
        let selectedText = pendingSelectedText
        let kbType = pendingKbType

        Task { [weak self] in
            guard let self = self else { return }
            let processed = await TextProcessor.shared.process(
                rawText,
                selectedText: selectedText,
                keyboardType: kbType
            )

            await MainActor.run {
                // 语音编辑模式: 先删除选中的文本
                if let selected = selectedText, !selected.isEmpty,
                   TextProcessor.shared.voiceEditEnabled {
                    self.textDocumentProxy.deleteBackward()
                }

                if !processed.isEmpty {
                    self.textDocumentProxy.insertText(processed)
                    let preview = processed.prefix(30)
                    self.liveTextLabel.text = "已输入 ✓  \(preview)\(processed.count > 30 ? "…" : "")"
                } else if selectedText != nil {
                    self.liveTextLabel.text = "已删除选中文字 ✓"
                } else {
                    // 处理结果为空,插入原始文本作为兜底
                    self.textDocumentProxy.insertText(rawText)
                    self.liveTextLabel.text = "已输入 ✓"
                }

                self.micButton.backgroundColor = UIColor.systemBlue
            }
        }
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
        waveLayer.strokeColor = UIColor.systemBlue.cgColor
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
