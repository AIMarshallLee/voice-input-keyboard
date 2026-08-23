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
    private var dictationFailedObserver: DarwinNotificationObserver?

    // MARK: - 通信状态
    private var isWaitingForResult = false
    private var currentSessionId: String?
    private var darwinFallbackTimer: Timer?
    private var resultTimeoutTimer: Timer?
    private var recoveredPendingSessionId: String?

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
        hasDictationKey = true
        setupUI()
        setupDarwinObservers()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 同步设置(用户可能在宿主 App 中修改了设置)
        updateTranslateButton()
        updateLangButton()
        checkForPendingResult()
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

        dictationStoppedObserver = DarwinNotificationObserver(
            name: DarwinNotificationName.dictationStopped
        ) {
            print("[KB] Received dictationStopped")
        }
    }

    private func configureSessionObservers(for sessionId: String) -> Bool {
        guard let startedName = DarwinBridge.sessionNotificationName(
            base: DarwinNotificationName.dictationStarted,
            session: sessionId
        ), let failedName = DarwinBridge.sessionNotificationName(
            base: DarwinNotificationName.dictationFailed,
            session: sessionId
        ) else { return false }

        dictationStartedObserver = DarwinNotificationObserver(name: startedName) { [weak self] in
            self?.onDictationStarted(sessionId: sessionId)
        }
        dictationFailedObserver = DarwinNotificationObserver(name: failedName) { [weak self] in
            self?.onDictationFailed(sessionId: sessionId)
        }
        return true
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

        if recoveredPendingSessionId != nil {
            confirmRecoveredResult()
            return
        }

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

    // MARK: - 无跳转启动听写

    /// 无跳转触发 (Typeless / 微信输入法同款方案):
    /// 1. 总是先发 Darwin 通知给主 App (不切 App!)
    /// 2. 主 App 在后台保活中 → 立即响应 dictationStarted → 不跳转
    /// 3. 主 App 尝试后台识别:
    ///    a) 识别成功 → transcriptionReady → 插入文字，全程不跳转！
    ///    b) 识别失败 → dictationFailed → 立即降级 URL Scheme → 前台识别
    /// 4. 主 App 不在保活中 → 1.5s 超时降级到 URL Scheme (首次使用)
    private func launchDictation() {
        guard hasFullAccess else {
            liveTextLabel.text = "请到设置→键盘→VoType→开启「允许完全访问」"
            return
        }

        let sessionId = UUID().uuidString
        currentSessionId = sessionId

        selectedTextBeforeRecording = textDocumentProxy.selectedText
        pendingSelectedText = selectedTextBeforeRecording
        pendingKbType = textDocumentProxy.keyboardType?.rawValue ?? 0

        let settings = DictationSettings(
            language: LanguageManager.shared.currentLanguage.id,
            whisper: isWhisperMode,
            translateEnabled: TranslationManager.shared.translationEnabled,
            translateTarget: TranslationManager.shared.targetLanguageID,
            selectedText: selectedTextBeforeRecording,
            keyboardType: pendingKbType,
            session: sessionId
        )
        guard DarwinBridge.writeDictationSettings(settings) else {
            resetWaitingState(message: "无法访问共享数据，请检查 App Group 配置")
            return
        }
        guard configureSessionObservers(for: sessionId) else {
            resetWaitingState(message: "无法创建安全的语音会话")
            return
        }

        isWaitingForResult = true
        recoveredPendingSessionId = nil
        liveTextLabel.text = "正在聆听..."
        startPulse()
        startResultTimeout(for: sessionId)

        // 麦克风按钮变声纹图标
        let waveConfig = UIImage.SymbolConfiguration(pointSize: 34, weight: .bold)
        micButton.setImage(UIImage(systemName: "waveform", withConfiguration: waveConfig), for: .normal)
        micButton.backgroundColor = UIColor.systemRed

        // 1.5s 超时: 主 App 不在后台保活中 (首次使用/被系统杀掉)
        // 收到 dictationStarted 会取消此 timer
        // 收到 dictationFailed 也会取消此 timer 并降级
        darwinFallbackTimer = Timer.scheduledTimer(
            withTimeInterval: 1.5,
            repeats: false
        ) { [weak self] _ in
            guard let self = self, self.isWaitingForResult else { return }
            print("[KB] No Darwin response in 1.5s, falling back to URL Scheme")
            self.launchViaURL(sessionId: sessionId)
        }

        // 观察者、状态和超时都就绪后再通知宿主 App，避免快速响应丢失。
        DarwinBridge.postNotification(DarwinNotificationName.requestStartDictation)
    }

    /// URL Scheme 降级路径
    private func launchViaURL(sessionId: String) {
        darwinFallbackTimer?.invalidate()
        darwinFallbackTimer = nil

        // URL 只传会话 UUID；设置和选中文本只保存在 App Group 中。
        guard let url = DictationConstants.buildDictationURL(session: sessionId) else {
            resetWaitingState(message: "无法创建语音输入 URL")
            return
        }

        isWaitingForResult = true

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
                            self.resetWaitingState(
                                message: "无法启动语音输入，请在一分钟内手动打开 VoType",
                                discardPendingSettings: false
                            )
                        }
                    }
                }
                launched = true
                break
            }
            responder = r.next
        }

        if !launched {
            resetWaitingState(
                message: "无法启动语音输入，请在一分钟内手动打开 VoType",
                discardPendingSettings: false
            )
        }
    }

    // MARK: - Darwin 通知回调

    /// 主 App 确认开始录音
    private func onDictationStarted(sessionId: String) {
        guard currentSessionId == sessionId, isWaitingForResult else { return }
        darwinFallbackTimer?.invalidate()
        darwinFallbackTimer = nil
        isWaitingForResult = true

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.liveTextLabel.text = "正在聆听..."
            // 声纹波浪图标 + 红色背景
            let waveConfig = UIImage.SymbolConfiguration(pointSize: 34, weight: .bold)
            self.micButton.setImage(UIImage(systemName: "waveform", withConfiguration: waveConfig), for: .normal)
            self.micButton.backgroundColor = UIColor.systemRed
        }
    }

    /// 主 App 后台识别失败 → 立即降级到 URL Scheme (前台识别)
    private func onDictationFailed(sessionId: String) {
        guard isWaitingForResult, currentSessionId == sessionId else { return }
        print("[KB] Background recognition failed, launching URL Scheme fallback")
        isWaitingForResult = false
        darwinFallbackTimer?.invalidate()
        darwinFallbackTimer = nil
        liveTextLabel.text = "正在启动语音输入..."
        launchViaURL(sessionId: sessionId)
    }

    /// 恢复麦克风按钮到默认状态 (录音结束/结果插入后调用)
    private func restoreMicButton() {
        let config = UIImage.SymbolConfiguration(pointSize: 34, weight: .bold)
        micButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: config), for: .normal)
        micButton.backgroundColor = UIColor.systemBlue
        stopPulse()
    }

    // MARK: - 处理识别结果

    /// 同一内存会话可自动接收；扩展重启后只能提示，必须再次点击麦克风确认。
    private func checkForPendingResult() {
        if isWaitingForResult, currentSessionId != nil {
            processPendingResult()
            return
        }
        guard let pending = DarwinBridge.peekResult() else { return }
        recoveredPendingSessionId = pending.session
        liveTextLabel.text = pending.status == .completed
            ? "检测到待插入结果，再点麦克风确认"
            : "检测到语音输入状态，再点麦克风查看"
        restoreMicButton()
        micButton.backgroundColor = .systemGreen
    }

    private func confirmRecoveredResult() {
        guard let session = recoveredPendingSessionId else { return }
        guard let result = DarwinBridge.readAndConsumeResult(expectedSession: session) else {
            recoveredPendingSessionId = nil
            restoreMicButton()
            liveTextLabel.text = "待插入结果已过期，请重新录音"
            return
        }
        DarwinBridge.discardResults(through: result.timestamp)
        currentSessionId = session
        recoveredPendingSessionId = nil
        finishWaitingState()
        handle(result)
    }

    private func processPendingResult() {
        guard isWaitingForResult, let session = currentSessionId else { return }
        guard let result = DarwinBridge.readAndConsumeResult(expectedSession: session) else {
            // session 不匹配或尚未写完时绝不消费现有文件。
            return
        }
        finishWaitingState()
        handle(result)
    }

    private func handle(_ result: DictationIPCResult) {
        if let text = result.transcription {
            insertResult(text, deleteSelected: result.deleteSelected)
        } else if let error = result.error {
            liveTextLabel.text = error
        }
        pendingSelectedText = nil
        currentSessionId = nil
    }

    private func finishWaitingState() {
        isWaitingForResult = false
        darwinFallbackTimer?.invalidate()
        darwinFallbackTimer = nil
        resultTimeoutTimer?.invalidate()
        resultTimeoutTimer = nil
        dictationStartedObserver = nil
        dictationFailedObserver = nil
        restoreMicButton()
    }

    private func resetWaitingState(
        message: String,
        discardPendingSettings: Bool = true
    ) {
        if discardPendingSettings, let session = currentSessionId {
            DarwinBridge.discardPendingDictationSettings(expectedSession: session)
        }
        finishWaitingState()
        currentSessionId = nil
        recoveredPendingSessionId = nil
        pendingSelectedText = nil
        liveTextLabel.text = message
    }

    private func startResultTimeout(for session: String) {
        resultTimeoutTimer?.invalidate()
        resultTimeoutTimer = Timer.scheduledTimer(
            withTimeInterval: 90,
            repeats: false
        ) { [weak self] _ in
            guard let self,
                  self.isWaitingForResult,
                  self.currentSessionId == session else { return }
            DarwinBridge.postSessionNotification(
                base: DarwinNotificationName.requestStopDictation,
                session: session
            )
            self.resetWaitingState(message: "语音输入超时，请重试")
        }
    }

    /// 插入识别结果到光标位置
    /// 主 App 已完成所有文字处理 (LLM/翻译/格式化/语音编辑)
    /// 键盘只负责插入,不跑任何 AI 模型
    private func insertResult(_ text: String, deleteSelected: Bool) {
        // 语音编辑结果只能作用于发起会话时的同一选区。切换 App 或扩展重启
        // 可能使选区丢失；此时宁可放弃结果，也不能误删光标前一个字符。
        if deleteSelected {
            guard let expectedSelection = pendingSelectedText,
                  !expectedSelection.isEmpty,
                  textDocumentProxy.selectedText == expectedSelection else {
                liveTextLabel.text = "选区已变化，请重新选择后录音"
                return
            }
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
        restoreMicButton()
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
