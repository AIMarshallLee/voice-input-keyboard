import UIKit

/// 语音输入键盘 - Darwin 通知 + 命名剪贴板 IPC 架构 (Build 16)
/// iOS 键盘扩展无法直接录音(平台限制)
///
/// 双路径触发:
/// 路径 A (首选): 心跳新鲜 → Darwin 通知 requestStartDictation → 主 App 录音 → transcriptionReady → 插入文字
/// 路径 B (降级): 心跳过期 → URL Scheme 启动主 App → 同上
///
/// 参考 Sayboard 架构
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

    // MARK: - Darwin 通知观察者
    private var transcriptionReadyObserver: DarwinNotificationObserver?
    private var transcriptionErrorObserver: DarwinNotificationObserver?
    private var dictationStartedObserver: DarwinNotificationObserver?
    private var dictationStoppedObserver: DarwinNotificationObserver?

    // MARK: - 通信状态
    private var isWaitingForResult = false
    private var currentSessionId: String?
    private var darwinFallbackTimer: Timer?

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
        setupDarwinObservers()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 同步设置(用户可能在宿主 App 中修改了设置)
        updateTranslateButton()
        updateLangButton()
        // 无条件检查剪贴板中是否有待处理结果
        // (键盘扩展可能被系统杀掉后重启,内存状态丢失,但剪贴板数据还在)
        checkAndProcessResult()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopPulse()
    }

    // MARK: - Darwin 通知注册

    /// 注册跨进程通知观察者
    /// 主 App 录音完成/出错时通过 Darwin 通知通知键盘
    private func setupDarwinObservers() {
        transcriptionReadyObserver = DarwinNotificationObserver(
            name: DarwinNotificationName.transcriptionReady
        ) { [weak self] in
            print("[KB] Received transcriptionReady")
            self?.processPendingResult()
        }

        transcriptionErrorObserver = DarwinNotificationObserver(
            name: DarwinNotificationName.transcriptionError
        ) { [weak self] in
            print("[KB] Received transcriptionError")
            self?.processPendingResult()
        }

        dictationStartedObserver = DarwinNotificationObserver(
            name: DarwinNotificationName.dictationStarted
        ) { [weak self] in
            print("[KB] Received dictationStarted")
            self?.onDictationStarted()
        }

        dictationStoppedObserver = DarwinNotificationObserver(
            name: DarwinNotificationName.dictationStopped
        ) {
            print("[KB] Received dictationStopped")
        }
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

        // 语言切换按钮
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

        spaceButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    // MARK: - 语言切换

    private func updateLangButton() {
        let lang = LanguageManager.shared.currentLanguage
        let title = "\(lang.flag) \(lang.id.split(separator: "-").first ?? "")"
        langButton.setTitle(title, for: .normal)
        langButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .medium)
    }

    @objc private func langTapped() {
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
        // 触感反馈
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()

        if isWaitingForResult {
            liveTextLabel.text = "正在等待语音结果..."
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

    // MARK: - 双路径启动听写

    /// 双路径触发:
    /// 1. 检查心跳 → 如果主 App 存活,发 Darwin 通知 (不切 App,体验更好)
    /// 2. 心跳过期 → URL Scheme 启动主 App (降级)
    private func launchDictation() {
        guard hasFullAccess else {
            liveTextLabel.text = "请到设置→键盘→VoType→开启「允许完全访问」"
            return
        }

        // 生成会话 ID
        let sessionId = UUID().uuidString
        currentSessionId = sessionId

        // 暂存设置
        selectedTextBeforeRecording = textDocumentProxy.selectedText
        pendingSelectedText = selectedTextBeforeRecording
        pendingKbType = textDocumentProxy.keyboardType?.rawValue ?? 0

        // 写入听写设置到命名剪贴板 (供 Path A Darwin 路径使用)
        let settings = DictationSettings(
            language: LanguageManager.shared.currentLanguage.id,
            whisper: isWhisperMode,
            translateEnabled: TranslationManager.shared.translationEnabled,
            translateTarget: TranslationManager.shared.targetLanguageID,
            selectedText: selectedTextBeforeRecording,
            keyboardType: pendingKbType,
            session: sessionId
        )
        DarwinBridge.writeDictationSettings(settings)

        // 检查主 App 是否存活
        let heartbeatAge = DarwinBridge.heartbeatAge()
        print("[KB] Heartbeat age: \(heartbeatAge == .infinity ? "never" : "\(heartbeatAge)s")")

        if DarwinBridge.isMainAppAlive(threshold: 3.0) {
            // 路径 A: Darwin 通知 (主 App 存活,不切 App)
            print("[KB] Path A: Darwin notification")
            DarwinBridge.postNotification(DarwinNotificationName.requestStartDictation)

            // 2.5 秒超时兜底:如果主 App 没响应,降级到 URL
            darwinFallbackTimer = Timer.scheduledTimer(
                withTimeInterval: 2.5,
                repeats: false
            ) { [weak self] _ in
                guard let self = self, self.isWaitingForResult else { return }
                print("[KB] Darwin fallback: no response in 2.5s, trying URL")
                self.launchViaURL(sessionId: sessionId)
            }

            isWaitingForResult = true
            liveTextLabel.text = "正在启动语音输入..."
            startPulse()
        } else {
            // 路径 B: URL Scheme (主 App 已死,需要启动)
            print("[KB] Path B: URL Scheme (main app not alive)")
            launchViaURL(sessionId: sessionId)
        }
    }

    /// URL Scheme 降级路径
    private func launchViaURL(sessionId: String) {
        darwinFallbackTimer?.invalidate()
        darwinFallbackTimer = nil

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

    // MARK: - Darwin 通知回调

    /// 主 App 确认开始录音
    private func onDictationStarted() {
        darwinFallbackTimer?.invalidate()
        darwinFallbackTimer = nil
        isWaitingForResult = true

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.liveTextLabel.text = "正在聆听...可以滑回之前的App"
            self.micButton.backgroundColor = UIColor.systemRed
        }
    }

    // MARK: - 处理识别结果

    /// 无条件检查剪贴板中是否有结果(viewWillAppear 调用)
    /// 键盘扩展被系统杀掉后重启时,内存状态丢失,但剪贴板数据还在
    /// 此方法不依赖 isWaitingForResult 状态,直接读剪贴板
    private func checkAndProcessResult() {
        let result = DarwinBridge.readAndConsumeResult()

        // 剪贴板为空,说明没有待处理结果
        guard result.text != nil || result.error != nil else { return }

        // 有结果,恢复 session 并处理
        if let session = result.session {
            currentSessionId = session
        }
        isWaitingForResult = false
        darwinFallbackTimer?.invalidate()
        darwinFallbackTimer = nil
        stopPulse()
        micButton.backgroundColor = UIColor.systemBlue

        if let text = result.text {
            insertResult(text, deleteSelected: result.deleteSelected)
        } else if let error = result.error {
            liveTextLabel.text = error
        }
    }

    /// 读取命名剪贴板中的结果
    /// 在 Darwin 通知回调中调用(需要 isWaitingForResult 为 true)
    private func processPendingResult() {
        guard isWaitingForResult else { return }

        let result = DarwinBridge.readAndConsumeResult()

        // 验证 session ID (防止过期结果串台)
        if let session = result.session, session != currentSessionId {
            print("[KB] Session mismatch: expected \(currentSessionId?.prefix(8) ?? "nil"), got \(session.prefix(8))")
            return
        }

        if let text = result.text {
            isWaitingForResult = false
            darwinFallbackTimer?.invalidate()
            darwinFallbackTimer = nil
            stopPulse()
            micButton.backgroundColor = UIColor.systemBlue
            insertResult(text, deleteSelected: result.deleteSelected)
        } else if let error = result.error {
            isWaitingForResult = false
            darwinFallbackTimer?.invalidate()
            darwinFallbackTimer = nil
            stopPulse()
            micButton.backgroundColor = UIColor.systemBlue
            liveTextLabel.text = error
        }
    }

    /// 插入识别结果到光标位置
    /// 主 App 已完成所有文字处理 (LLM/翻译/格式化/语音编辑)
    /// 键盘只负责插入,不跑任何 AI 模型
    private func insertResult(_ text: String, deleteSelected: Bool) {
        // ★ 先处理 deleteSelected,即使 text 为空也要删除选中文本
        // 语音编辑的"删除"模式: text 为空但 deleteSelected 为 true
        if deleteSelected {
            textDocumentProxy.deleteBackward()
        }

        if text.isEmpty {
            if deleteSelected {
                liveTextLabel.text = "已删除选中文本 ✓"
            } else {
                liveTextLabel.text = "未识别到语音,请重试"
            }
            return
        }

        textDocumentProxy.insertText(text)

        let preview = text.prefix(30)
        liveTextLabel.text = "已输入 ✓  \(preview)\(text.count > 30 ? "…" : "")"
        micButton.backgroundColor = UIColor.systemBlue
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
