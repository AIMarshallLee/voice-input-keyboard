import UIKit

/// 语音输入键盘 - Darwin 通知 + 命名剪贴板 IPC 架构 (Build 16)
/// iOS 键盘扩展无法直接录音(平台限制)
///
/// 启动路径: 新鲜待命可原地请求；否则保存会话并提示用户手动打开 VoType。
/// 手动返回与重建后的结果必须经用户明确操作后才写入输入框。
///
/// 参考 Sayboard 架构
class KeyboardViewController: UIInputViewController, UIGestureRecognizerDelegate {

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
    private let heldResultActionView = HeldResultActionView(frame: .zero)
    private let symbolStack = UIStackView()
    private let quickTypeButton = UIButton(type: .system)
    private let quickTypeContainerView = UIView()
    private let quickTypeRowsStack = UIStackView()
    private let quickTypeStatusButton = UIButton(type: .system)
    private let pinyinCandidateScrollView = UIScrollView()
    private let pinyinCandidateStack = UIStackView()
    private let pinyinCompositionLabel = UILabel()
    private var deleteTimer: Timer?

    // MARK: - Darwin 通知观察者
    private var transcriptionReadyObserver: DarwinNotificationObserver?
    private var transcriptionErrorObserver: DarwinNotificationObserver?
    private var dictationStartedObserver: DarwinNotificationObserver?
    private var dictationStoppedObserver: DarwinNotificationObserver?
    private var dictationFailedObserver: DarwinNotificationObserver?
    private var liveStateChangedObserver: DarwinNotificationObserver?
    private var pinyinLearningResetObserver: DarwinNotificationObserver?

    // MARK: - 通信状态
    private var isWaitingForResult = false
    private var currentSessionId: String?
    private lazy var hotAckCoordinator = DictationHotAckCoordinator(scheduler: TimerKeyboardLaunchScheduler())
    private var currentExtensionSessionToken: SessionToken?
    private var currentDictationSettings: DictationSettings?
    private var failedHandoffRetryToken: SessionToken?
    private var deferredTerminalToken: SessionToken?
    private var resultTimeoutTimer: Timer?
    private var resultTimeoutGeneration = UUID()
    private var liveStatePollTimer: Timer?
    private var readinessPollTimer: Timer?
    private var currentHeldSession: String?
    private var heldResultPreview: DictationIPCResult?
    private var recoveredSnapshot: KeyboardSessionRecoverySnapshot?
    private var currentLivePhase: DictationLivePhase?
    private var keyboardIsVisible = false
    private var requiresContextRevalidation = false

    // 暂存启动时的设置,处理结果时使用
    private var pendingKbType: Int = 0

    // MARK: - 模式状态
    private var isWhisperMode = false

    private enum QuickTypeLayout: Equatable {
        case letters
        case numbers
        case symbols
    }

    private enum TypingLanguage {
        case chinese
        case english
    }

    private var quickTypeLayout: QuickTypeLayout = .letters
    private var isShifted = true
    private var typingLanguage: TypingLanguage = .chinese
    private var pinyinComposition = ""
    private var visiblePinyinCandidates: [String] = []
    private var pinyinEngine: PinyinInputEngine?
    private var pinyinLoadGeneration: UInt = 0

    // MARK: - 快捷符号
    private let symbols = ["，", "。", "！", "？", "、", "：", "；", "\u{201C}", "\u{201D}", "（", "）", "…", "—", "～", "😊", "👍", "✅"]

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        KeyboardSetupStatusStore.recordExtensionAppearance(
            hasFullAccess: hasFullAccess
        )
        hasDictationKey = true
        setupUI()
        setupQuickTypingUI()
        setupDarwinObservers()
        preloadPinyinEngine()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        KeyboardSetupStatusStore.recordExtensionAppearance(
            hasFullAccess: hasFullAccess
        )
        keyboardIsVisible = true
        // 同步设置(用户可能在宿主 App 中修改了设置)
        updateTranslateButton()
        updateLangButton()
        checkForPendingResult()
        startReadinessPolling()
        if isWaitingForResult, let session = currentSessionId {
            startLiveStatePolling(for: session)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        keyboardIsVisible = false
        if isWaitingForResult {
            requiresContextRevalidation = true
        }
        deleteTimer?.invalidate()
        deleteTimer = nil
        liveStatePollTimer?.invalidate()
        liveStatePollTimer = nil
        readinessPollTimer?.invalidate()
        readinessPollTimer = nil
        stopPulse()
    }

    deinit {
        deleteTimer?.invalidate()
        MainActor.assumeIsolated { hotAckCoordinator.cancel() }
        resultTimeoutTimer?.invalidate()
        liveStatePollTimer?.invalidate()
        readinessPollTimer?.invalidate()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        if isWaitingForResult {
            // 控制器可能在输入框切换时保持可见；任何文档变化都要求在终态
            // 写回前重新核对上下文。会话期间主动补字时则安全降级为点按确认。
            requiresContextRevalidation = true
        }
        if !quickTypeContainerView.isHidden {
            refreshShiftAfterEditing()
        }
    }

    override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
        if isWaitingForResult {
            requiresContextRevalidation = true
        }
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

        pinyinLearningResetObserver = DarwinNotificationObserver(
            name: DarwinNotificationName.pinyinLearningReset
        ) { [weak self] in
            self?.pinyinEngine = nil
            self?.refreshPinyinCandidates()
            self?.preloadPinyinEngine()
        }
    }

    private func configureSessionObservers(for sessionId: String) -> Bool {
        guard let startedName = DarwinBridge.sessionNotificationName(
            base: DarwinNotificationName.dictationStarted,
            session: sessionId
        ), let failedName = DarwinBridge.sessionNotificationName(
            base: DarwinNotificationName.dictationFailed,
            session: sessionId
        ), let liveStateName = DarwinBridge.sessionNotificationName(
            base: DarwinNotificationName.liveStateChanged,
            session: sessionId
        ) else { return false }

        dictationStartedObserver = DarwinNotificationObserver(name: startedName) { [weak self] in
            self?.onDictationStarted(sessionId: sessionId)
        }
        dictationFailedObserver = DarwinNotificationObserver(name: failedName) { [weak self] in
            self?.onDictationFailed(sessionId: sessionId)
        }
        liveStateChangedObserver = DarwinNotificationObserver(name: liveStateName) { [weak self] in
            self?.refreshLiveState(for: sessionId)
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
        micButton.accessibilityLabel = "语音输入"
        micButton.accessibilityHint = "开始或结束当前语音会话"
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)

        // 快速补字入口：不需要「允许完全访问」，直接使用 textDocumentProxy。
        let quickTypeConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        quickTypeButton.setImage(
            UIImage(systemName: "keyboard", withConfiguration: quickTypeConfig),
            for: .normal
        )
        quickTypeButton.tintColor = textColor
        quickTypeButton.backgroundColor = buttonColor
        quickTypeButton.layer.cornerRadius = 8
        quickTypeButton.translatesAutoresizingMaskIntoConstraints = false
        quickTypeButton.accessibilityLabel = "打开中文拼音与英文键盘"
        quickTypeButton.addTarget(
            self,
            action: #selector(showQuickTyping),
            for: .touchUpInside
        )

        // 实时文字
        liveTextLabel.font = UIFont.systemFont(ofSize: 15)
        liveTextLabel.textColor = textColor.withAlphaComponent(0.6)
        liveTextLabel.textAlignment = .center
        liveTextLabel.numberOfLines = 2
        liveTextLabel.text = "点击麦克风开始语音输入"
        liveTextLabel.translatesAutoresizingMaskIntoConstraints = false
        liveTextLabel.accessibilityTraits.insert(.updatesFrequently)

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
        globeButton.accessibilityLabel = "下一个键盘"
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
        translateButton.accessibilityHint = "开启或关闭语音翻译"
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
        whisperButton.accessibilityHint = "开启或关闭耳语模式"
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
        deleteButton.accessibilityLabel = "退格"
        deleteButton.accessibilityHint = "按住可连续删除"
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
        returnButton.accessibilityLabel = "回车"
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
        containerView.addSubview(quickTypeButton)
        containerView.addSubview(liveTextLabel)
        containerView.addSubview(waveformView)
        containerView.addSubview(symbolBar)
        containerView.addSubview(heldResultActionView)
        heldResultActionView.onInsert = { [weak self] in self?.insertHeldResult() }
        heldResultActionView.onCopy = { [weak self] in self?.copyHeldResult() }
        heldResultActionView.onDiscard = { [weak self] in self?.discardHeldResult() }
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

            quickTypeButton.trailingAnchor.constraint(
                equalTo: containerView.trailingAnchor,
                constant: -12
            ),
            quickTypeButton.centerYAnchor.constraint(equalTo: micButton.centerYAnchor),
            quickTypeButton.widthAnchor.constraint(equalToConstant: 44),
            quickTypeButton.heightAnchor.constraint(equalToConstant: 36),

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

            heldResultActionView.topAnchor.constraint(equalTo: symbolBar.topAnchor),
            heldResultActionView.leadingAnchor.constraint(equalTo: symbolBar.leadingAnchor),
            heldResultActionView.trailingAnchor.constraint(equalTo: symbolBar.trailingAnchor),
            heldResultActionView.heightAnchor.constraint(equalTo: symbolBar.heightAnchor),

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

        let swipeToType = UISwipeGestureRecognizer(
            target: self,
            action: #selector(showQuickTyping)
        )
        swipeToType.direction = .left
        swipeToType.cancelsTouchesInView = false
        swipeToType.delegate = self
        containerView.addGestureRecognizer(swipeToType)
    }

    // MARK: - 中文拼音与英文快速补字键盘

    private func setupQuickTypingUI() {
        quickTypeContainerView.backgroundColor = .clear
        quickTypeContainerView.translatesAutoresizingMaskIntoConstraints = false
        quickTypeContainerView.isHidden = true
        view.addSubview(quickTypeContainerView)

        quickTypeStatusButton.translatesAutoresizingMaskIntoConstraints = false
        quickTypeStatusButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
        quickTypeStatusButton.layer.cornerRadius = 7
        quickTypeStatusButton.titleLabel?.font = UIFont.systemFont(
            ofSize: 12,
            weight: .medium
        )
        quickTypeStatusButton.titleLabel?.lineBreakMode = .byTruncatingTail
        quickTypeStatusButton.contentHorizontalAlignment = .center
        quickTypeStatusButton.accessibilityLabel = "语音输入状态"
        quickTypeStatusButton.addTarget(
            self,
            action: #selector(quickTypeStatusTapped),
            for: .touchUpInside
        )
        quickTypeContainerView.addSubview(quickTypeStatusButton)
        updateQuickTypeStatus("语音输入", phase: nil)

        pinyinCandidateScrollView.translatesAutoresizingMaskIntoConstraints = false
        pinyinCandidateScrollView.showsHorizontalScrollIndicator = false
        pinyinCandidateScrollView.backgroundColor = UIColor.secondarySystemBackground
        pinyinCandidateScrollView.layer.cornerRadius = 7
        quickTypeContainerView.addSubview(pinyinCandidateScrollView)

        pinyinCandidateStack.axis = .horizontal
        pinyinCandidateStack.alignment = .fill
        pinyinCandidateStack.spacing = 4
        pinyinCandidateStack.translatesAutoresizingMaskIntoConstraints = false
        pinyinCandidateScrollView.addSubview(pinyinCandidateStack)

        pinyinCompositionLabel.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        pinyinCompositionLabel.textColor = .systemBlue
        pinyinCompositionLabel.text = "拼音"
        pinyinCompositionLabel.textAlignment = .center
        pinyinCompositionLabel.accessibilityLabel = "正在输入的拼音"
        pinyinCompositionLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        pinyinCandidateStack.addArrangedSubview(pinyinCompositionLabel)

        quickTypeRowsStack.axis = .vertical
        quickTypeRowsStack.spacing = 6
        quickTypeRowsStack.distribution = .fillEqually
        quickTypeRowsStack.translatesAutoresizingMaskIntoConstraints = false
        quickTypeContainerView.addSubview(quickTypeRowsStack)

        NSLayoutConstraint.activate([
            quickTypeContainerView.topAnchor.constraint(equalTo: view.topAnchor),
            quickTypeContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            quickTypeContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            quickTypeContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            quickTypeStatusButton.topAnchor.constraint(
                equalTo: quickTypeContainerView.topAnchor,
                constant: 4
            ),
            quickTypeStatusButton.leadingAnchor.constraint(
                equalTo: quickTypeContainerView.leadingAnchor,
                constant: 6
            ),
            quickTypeStatusButton.trailingAnchor.constraint(
                equalTo: quickTypeContainerView.trailingAnchor,
                constant: -6
            ),
            quickTypeStatusButton.heightAnchor.constraint(equalToConstant: 28),

            pinyinCandidateScrollView.leadingAnchor.constraint(
                equalTo: quickTypeContainerView.leadingAnchor,
                constant: 6
            ),
            pinyinCandidateScrollView.trailingAnchor.constraint(
                equalTo: quickTypeContainerView.trailingAnchor,
                constant: -6
            ),
            pinyinCandidateScrollView.topAnchor.constraint(
                equalTo: quickTypeStatusButton.bottomAnchor,
                constant: 3
            ),
            pinyinCandidateScrollView.heightAnchor.constraint(equalToConstant: 32),

            pinyinCandidateStack.topAnchor.constraint(equalTo: pinyinCandidateScrollView.topAnchor),
            pinyinCandidateStack.bottomAnchor.constraint(equalTo: pinyinCandidateScrollView.bottomAnchor),
            pinyinCandidateStack.leadingAnchor.constraint(
                equalTo: pinyinCandidateScrollView.leadingAnchor,
                constant: 4
            ),
            pinyinCandidateStack.trailingAnchor.constraint(
                equalTo: pinyinCandidateScrollView.trailingAnchor,
                constant: -4
            ),

            quickTypeRowsStack.leadingAnchor.constraint(
                equalTo: quickTypeContainerView.leadingAnchor,
                constant: 6
            ),
            quickTypeRowsStack.trailingAnchor.constraint(
                equalTo: quickTypeContainerView.trailingAnchor,
                constant: -6
            ),
            quickTypeRowsStack.topAnchor.constraint(
                equalTo: pinyinCandidateScrollView.bottomAnchor,
                constant: 3
            ),
            quickTypeRowsStack.bottomAnchor.constraint(
                equalTo: quickTypeContainerView.bottomAnchor,
                constant: -6
            ),
        ])

        let swipeToVoice = UISwipeGestureRecognizer(
            target: self,
            action: #selector(showVoiceInput)
        )
        swipeToVoice.direction = .right
        swipeToVoice.cancelsTouchesInView = false
        swipeToVoice.delegate = self
        quickTypeContainerView.addGestureRecognizer(swipeToVoice)

        rebuildQuickTypingKeyboard()
        refreshPinyinCandidates()
    }

    private func rebuildQuickTypingKeyboard() {
        for row in quickTypeRowsStack.arrangedSubviews {
            quickTypeRowsStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }

        for keys in quickTypeCharacterRows() {
            quickTypeRowsStack.addArrangedSubview(
                makeQuickTypeRow(keys: keys, isBottomRow: false)
            )
        }
        quickTypeRowsStack.addArrangedSubview(
            makeQuickTypeRow(keys: quickTypeBottomRow(), isBottomRow: true)
        )
    }

    private func quickTypeCharacterRows() -> [[String]] {
        switch quickTypeLayout {
        case .letters:
            if typingLanguage == .chinese {
                return [
                    ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
                    ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
                    ["z", "x", "c", "v", "b", "n", "m", "delete"],
                ]
            }
            return [
                ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
                ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
                ["shift", "z", "x", "c", "v", "b", "n", "m", "delete"],
            ]
        case .numbers:
            return [
                ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
                ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
                ["#+=", ".", ",", "?", "!", "'", "delete"],
            ]
        case .symbols:
            return [
                ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
                ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"],
                ["123", ".", ",", "?", "!", "'", "delete"],
            ]
        }
    }

    private func quickTypeBottomRow() -> [String] {
        let modeKey = quickTypeLayout == .letters ? "123" : "ABC"
        return [modeKey, "globe", "language", "voice", "space", "return"]
    }

    private func makeQuickTypeRow(
        keys: [String],
        isBottomRow: Bool
    ) -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .fill
        row.spacing = isBottomRow ? 5 : 4
        row.distribution = isBottomRow ? .fill : .fillEqually

        for key in keys {
            let button = makeQuickTypeButton(for: key)
            row.addArrangedSubview(button)

            guard isBottomRow else { continue }
            switch key {
            case "123", "ABC":
                button.widthAnchor.constraint(equalToConstant: 52).isActive = true
            case "globe":
                button.widthAnchor.constraint(equalToConstant: 42).isActive = true
            case "language":
                button.widthAnchor.constraint(equalToConstant: 44).isActive = true
            case "voice":
                button.widthAnchor.constraint(equalToConstant: 46).isActive = true
            case "return":
                button.widthAnchor.constraint(equalToConstant: 50).isActive = true
            case "space":
                button.setContentHuggingPriority(.defaultLow, for: .horizontal)
                button.setContentCompressionResistancePriority(
                    .defaultLow,
                    for: .horizontal
                )
            default:
                break
            }
        }
        return row
    }

    private func makeQuickTypeButton(for key: String) -> UIButton {
        let button = UIButton(type: .system)
        let isDark = traitCollection.userInterfaceStyle == .dark
        let keyColor = isDark
            ? UIColor(white: 0.18, alpha: 1)
            : UIColor.white
        let specialKeyColor = isDark
            ? UIColor(white: 0.28, alpha: 1)
            : UIColor(white: 0.80, alpha: 1)
        let textColor = isDark ? UIColor.white : UIColor.black
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)

        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityIdentifier = key
        button.tintColor = textColor
        button.setTitleColor(textColor, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .regular)
        button.backgroundColor = keyColor
        button.layer.cornerRadius = 8
        button.addTarget(self, action: #selector(quickTypeKeyTapped(_:)), for: .touchUpInside)

        switch key {
        case "shift":
            button.setImage(
                UIImage(
                    systemName: isShifted ? "shift.fill" : "shift",
                    withConfiguration: symbolConfig
                ),
                for: .normal
            )
            button.backgroundColor = isShifted ? .systemBlue : specialKeyColor
            button.tintColor = isShifted ? .white : textColor
            button.accessibilityLabel = "Shift"
            button.accessibilityValue = isShifted ? "开启" : "关闭"
            button.accessibilityTraits = .button
            if isShifted {
                button.accessibilityTraits = [.button, .selected]
            }
        case "delete":
            button.setImage(
                UIImage(systemName: "delete.left", withConfiguration: symbolConfig),
                for: .normal
            )
            button.backgroundColor = specialKeyColor
            button.accessibilityLabel = "退格"
            let longPress = UILongPressGestureRecognizer(
                target: self,
                action: #selector(handleLongPressDelete(_:))
            )
            button.addGestureRecognizer(longPress)
        case "globe":
            button.setImage(
                UIImage(systemName: "globe", withConfiguration: symbolConfig),
                for: .normal
            )
            button.backgroundColor = specialKeyColor
            button.accessibilityLabel = "下一个键盘"
        case "language":
            button.setTitle(typingLanguage == .chinese ? "中" : "英", for: .normal)
            button.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
            button.backgroundColor = typingLanguage == .chinese ? .systemBlue : specialKeyColor
            button.setTitleColor(typingLanguage == .chinese ? .white : textColor, for: .normal)
            button.accessibilityLabel = "中英文切换"
            button.accessibilityValue = typingLanguage == .chinese ? "中文拼音" : "英文"
        case "voice":
            button.setImage(
                UIImage(systemName: "mic.fill", withConfiguration: symbolConfig),
                for: .normal
            )
            button.backgroundColor = .systemBlue
            button.tintColor = .white
            button.accessibilityLabel = "返回语音输入"
        case "space":
            button.setTitle(typingLanguage == .chinese ? "空格" : "space", for: .normal)
            button.titleLabel?.font = UIFont.systemFont(ofSize: 14)
            button.backgroundColor = keyColor
            button.accessibilityLabel = "空格"
        case "return":
            button.setImage(
                UIImage(systemName: "return", withConfiguration: symbolConfig),
                for: .normal
            )
            button.backgroundColor = specialKeyColor
            button.accessibilityLabel = "回车"
        case "123", "ABC", "#+=":
            button.setTitle(key, for: .normal)
            button.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .medium)
            button.backgroundColor = specialKeyColor
            button.accessibilityLabel = key == "ABC" ? "英文字母" : "数字与符号"
        default:
            let title = quickTypeLayout == .letters && isShifted && typingLanguage == .english
                ? key.uppercased()
                : key
            button.setTitle(title, for: .normal)
            button.accessibilityLabel = title
        }

        return button
    }

    @objc private func showQuickTyping() {
        updateQuickTypeStatus(
            liveTextLabel.text ?? "语音输入",
            phase: currentLivePhase
        )
        if quickTypeLayout == .letters, typingLanguage == .english {
            isShifted = shouldAutoCapitalize()
            rebuildQuickTypingKeyboard()
        }
        guard quickTypeContainerView.isHidden else { return }
        UIView.transition(
            with: view,
            duration: 0.18,
            options: [.transitionCrossDissolve, .allowAnimatedContent]
        ) {
            self.containerView.isHidden = true
            self.quickTypeContainerView.isHidden = false
        }
    }

    @objc private func showVoiceInput() {
        guard containerView.isHidden else { return }
        UIView.transition(
            with: view,
            duration: 0.18,
            options: [.transitionCrossDissolve, .allowAnimatedContent]
        ) {
            self.quickTypeContainerView.isHidden = true
            self.containerView.isHidden = false
        }
    }

    @objc private func quickTypeStatusTapped() {
        if isWaitingForResult {
            micTapped()
        } else {
            showVoiceInput()
        }
    }

    private func updateQuickTypeStatus(
        _ text: String,
        phase: DictationLivePhase?
    ) {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        quickTypeStatusButton.setTitle(
            title.isEmpty ? "语音输入" : title,
            for: .normal
        )
        quickTypeStatusButton.accessibilityValue = title
        switch phase {
        case .starting:
            quickTypeStatusButton.tintColor = .systemOrange
            quickTypeStatusButton.setTitleColor(.systemOrange, for: .normal)
            quickTypeStatusButton.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.12)
        case .listening:
            quickTypeStatusButton.tintColor = .systemRed
            quickTypeStatusButton.setTitleColor(.systemRed, for: .normal)
            quickTypeStatusButton.backgroundColor = UIColor.systemRed.withAlphaComponent(0.12)
        case .processing:
            quickTypeStatusButton.tintColor = .secondaryLabel
            quickTypeStatusButton.setTitleColor(.secondaryLabel, for: .normal)
            quickTypeStatusButton.backgroundColor = UIColor.secondarySystemFill
        case .none:
            quickTypeStatusButton.tintColor = .systemBlue
            quickTypeStatusButton.setTitleColor(.systemBlue, for: .normal)
            quickTypeStatusButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
        }
    }

    @objc private func quickTypeKeyTapped(_ sender: UIButton) {
        guard let key = sender.accessibilityIdentifier else { return }

        switch key {
        case "shift":
            guard typingLanguage == .english else { return }
            isShifted.toggle()
            rebuildQuickTypingKeyboard()
        case "delete":
            performQuickTypeDelete()
        case "space":
            if !commitCurrentPinyin() {
                textDocumentProxy.insertText(" ")
            }
        case "return":
            _ = commitCurrentPinyin()
            textDocumentProxy.insertText("\n")
            if quickTypeLayout == .letters,
               typingLanguage == .english,
               !isShifted {
                isShifted = true
                rebuildQuickTypingKeyboard()
            }
        case "123":
            _ = commitCurrentPinyin()
            quickTypeLayout = .numbers
            rebuildQuickTypingKeyboard()
        case "ABC":
            quickTypeLayout = .letters
            isShifted = typingLanguage == .english && shouldAutoCapitalize()
            rebuildQuickTypingKeyboard()
        case "#+=":
            _ = commitCurrentPinyin()
            quickTypeLayout = .symbols
            rebuildQuickTypingKeyboard()
        case "globe":
            _ = commitCurrentPinyin()
            advanceToNextInputMode()
        case "language":
            _ = commitCurrentPinyin()
            typingLanguage = typingLanguage == .chinese ? .english : .chinese
            quickTypeLayout = .letters
            isShifted = typingLanguage == .english && shouldAutoCapitalize()
            refreshPinyinCandidates()
            rebuildQuickTypingKeyboard()
        case "voice":
            _ = commitCurrentPinyin()
            if isWaitingForResult {
                micTapped()
            } else {
                showVoiceInput()
            }
        default:
            if typingLanguage == .chinese, quickTypeLayout == .letters {
                pinyinComposition.append(contentsOf: key.lowercased())
                refreshPinyinCandidates()
                return
            }
            let text = quickTypeLayout == .letters && isShifted
                ? key.uppercased()
                : key
            textDocumentProxy.insertText(text)
            if quickTypeLayout == .letters, isShifted {
                isShifted = false
                rebuildQuickTypingKeyboard()
            }
        }
    }

    private func performQuickTypeDelete() {
        if typingLanguage == .chinese, !pinyinComposition.isEmpty {
            pinyinComposition.removeLast()
            refreshPinyinCandidates()
            return
        }
        textDocumentProxy.deleteBackward()
        refreshShiftAfterEditing()
    }

    @discardableResult
    private func commitCurrentPinyin(candidateIndex: Int = 0) -> Bool {
        guard typingLanguage == .chinese, !pinyinComposition.isEmpty else {
            return false
        }

        let output: String
        if visiblePinyinCandidates.indices.contains(candidateIndex) {
            output = visiblePinyinCandidates[candidateIndex]
            pinyinEngine?.recordSelection(
                input: pinyinComposition,
                candidate: output
            )
        } else {
            output = pinyinComposition
        }
        textDocumentProxy.insertText(output)
        pinyinComposition = ""
        refreshPinyinCandidates()
        return true
    }

    private func refreshPinyinCandidates() {
        for view in pinyinCandidateStack.arrangedSubviews where view !== pinyinCompositionLabel {
            pinyinCandidateStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        guard typingLanguage == .chinese else {
            pinyinCompositionLabel.text = "英文"
            visiblePinyinCandidates = []
            return
        }

        guard !pinyinComposition.isEmpty else {
            pinyinCompositionLabel.text = "拼音"
            visiblePinyinCandidates = []
            addPinyinHint("输入拼音，空格选首词")
            return
        }

        pinyinCompositionLabel.text = pinyinComposition
        guard let pinyinEngine else {
            visiblePinyinCandidates = []
            addPinyinHint("正在加载中文词库…")
            return
        }
        visiblePinyinCandidates = pinyinEngine.candidates(
            for: pinyinComposition,
            limit: 12
        )

        if visiblePinyinCandidates.isEmpty {
            addPinyinHint("继续输入或空格上屏拼音")
        } else {
            for (index, candidate) in visiblePinyinCandidates.enumerated() {
                let button = UIButton(type: .system)
                button.setTitle(candidate, for: .normal)
                button.titleLabel?.font = UIFont.systemFont(ofSize: 17)
                button.setTitleColor(.label, for: .normal)
                button.backgroundColor = index == 0
                    ? UIColor.systemBlue.withAlphaComponent(0.12)
                    : .clear
                button.layer.cornerRadius = 6
                button.contentEdgeInsets = UIEdgeInsets(top: 2, left: 10, bottom: 2, right: 10)
                button.accessibilityIdentifier = String(index)
                button.accessibilityLabel = "候选词 \(candidate)"
                button.addTarget(
                    self,
                    action: #selector(pinyinCandidateTapped(_:)),
                    for: .touchUpInside
                )
                pinyinCandidateStack.addArrangedSubview(button)
            }
        }
        pinyinCandidateScrollView.setContentOffset(.zero, animated: false)
    }

    /// 6 万词条解析不占用键盘首帧主线程。用户立刻打开普通键盘时仍可先
    /// 输入拼音，词库就绪后自动刷新当前组合，不制造卡死或丢键。
    private func preloadPinyinEngine() {
        pinyinLoadGeneration &+= 1
        let generation = pinyinLoadGeneration
        let resourceBundle = Bundle.main
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let engine = PinyinInputEngine(bundle: resourceBundle)
            DispatchQueue.main.async {
                guard let self,
                      self.pinyinLoadGeneration == generation else { return }
                self.pinyinEngine = engine
                if self.typingLanguage == .chinese,
                   !self.pinyinComposition.isEmpty {
                    self.refreshPinyinCandidates()
                }
            }
        }
    }

    private func addPinyinHint(_ text: String) {
        let label = UILabel()
        label.text = text
        label.textColor = .secondaryLabel
        label.font = UIFont.systemFont(ofSize: 12)
        pinyinCandidateStack.addArrangedSubview(label)
    }

    @objc private func pinyinCandidateTapped(_ sender: UIButton) {
        guard let identifier = sender.accessibilityIdentifier,
              let index = Int(identifier) else { return }
        _ = commitCurrentPinyin(candidateIndex: index)
    }

    private func refreshShiftAfterEditing() {
        guard quickTypeLayout == .letters,
              typingLanguage == .english,
              deleteTimer == nil else { return }
        let shouldShift = shouldAutoCapitalize()
        guard shouldShift != isShifted else { return }
        isShifted = shouldShift
        rebuildQuickTypingKeyboard()
    }

    private func shouldAutoCapitalize() -> Bool {
        guard let context = textDocumentProxy.documentContextBeforeInput,
              !context.isEmpty else { return true }
        if context.last == "\n" { return true }
        guard let lastNonWhitespace = context.last(where: { !$0.isWhitespace }) else {
            return true
        }
        return ".!?".contains(lastNonWhitespace)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard gestureRecognizer.view === containerView,
              let touchedView = touch.view else { return true }
        return touchedView !== symbolBar && !touchedView.isDescendant(of: symbolBar)
            && touchedView !== heldResultActionView && !touchedView.isDescendant(of: heldResultActionView)
    }

    // MARK: - 语言切换

    private func updateLangButton() {
        let lang = LanguageManager.shared.currentLanguage
        let title = "\(lang.flag) \(lang.id.split(separator: "-").first ?? "")"
        langButton.setTitle(title, for: .normal)
        langButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        langButton.accessibilityLabel = "识别语言"
        langButton.accessibilityValue = lang.name
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
        translateButton.accessibilityLabel = "翻译模式"
        translateButton.accessibilityValue = isOn ? "开启" : "关闭"
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
        whisperButton.accessibilityLabel = "耳语模式"
        whisperButton.accessibilityValue = isWhisperMode ? "开启" : "关闭"
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

        if currentHeldSession != nil {
            showHeldResultMessage("请先选择插入、复制或丢弃当前结果")
            return
        }

        if let failedToken = failedHandoffRetryToken,
           currentSessionId == failedToken.rawValue {
            processPendingResult()
            guard failedHandoffRetryToken == failedToken,
                  currentSessionId == failedToken.rawValue, isWaitingForResult else { return }
            guard DarwinBridge.cancelSession(failedToken.rawValue) else {
                showFailedHandoffRetry(message: "暂时无法确认取消，请点麦克风重试")
                return
            }
            DarwinBridge.postSessionNotification(
                base: DarwinNotificationName.requestCancelDictation, session: failedToken.rawValue
            )
            finishSession(session: failedToken.rawValue, message: "正在重新创建语音会话")
            launchDictation()
            return
        }

        if isWaitingForResult {
            guard let session = currentSessionId else { return }
            refreshLiveState(for: session)
            guard isWaitingForResult,
                  currentSessionId == session else { return }
            switch currentLivePhase {
            case .listening:
                currentLivePhase = .processing
                liveTextLabel.text = "正在完成识别..."
                updateQuickTypeStatus("正在完成识别...", phase: .processing)
                micButton.isEnabled = false
                DarwinBridge.postSessionNotification(
                    base: DarwinNotificationName.requestStopDictation,
                    session: session
                )
            case .starting:
                guard DarwinBridge.cancelSession(session) else {
                    liveTextLabel.text = "暂时无法确认取消，仍在等待 VoType"
                    updateQuickTypeStatus(
                        "暂时无法确认取消，仍在等待 VoType",
                        phase: .starting
                    )
                    startResultTimeout(for: session, interval: 15)
                    return
                }
                KeyboardSessionRecoveryStore.clear(expectedSession: session)
                DarwinBridge.postSessionNotification(
                    base: DarwinNotificationName.requestCancelDictation,
                    session: session
                )
                resetWaitingState(
                    message: "已取消本次语音输入",
                    discardPendingSettings: false
                )
            case .processing:
                liveTextLabel.text = "正在整理文字，请稍候..."
                updateQuickTypeStatus("正在整理文字，请稍候...", phase: .processing)
            case .none:
                liveTextLabel.text = "请打开 VoType 开始录音"
                updateQuickTypeStatus("请打开 VoType 开始录音", phase: .starting)
            }
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
                guard let self = self else { return }
                if self.quickTypeContainerView.isHidden {
                    self.textDocumentProxy.deleteBackward()
                } else {
                    self.performQuickTypeDelete()
                }
            }
        } else if gesture.state == .ended
            || gesture.state == .cancelled
            || gesture.state == .failed {
            deleteTimer?.invalidate()
            deleteTimer = nil
            if !quickTypeContainerView.isHidden {
                refreshShiftAfterEditing()
            }
        }
    }

    // MARK: - 启动听写

    /// 保存不可变设置和上下文指纹；冷路径只提示用户手动打开。
    private func launchDictation() {
        guard hasFullAccess else {
            liveTextLabel.text = "请到设置→键盘→VoType→开启「允许完全访问」"
            return
        }
        // Check durable handoffs before generating any fresh identity, even without a snapshot.
        switch DarwinBridge.handoffRecovery() {
        case .unavailable:
            showRecoveryStorageUnavailable()
            return
        case .unresolved(let replacement):
            let evidence = DarwinBridge.recoverySessionEvidence(for: replacement)
            if evidence.hasResult || evidence.hasActiveRequest {
                recoveredSnapshot = KeyboardSessionRecoveryStore.load().flatMap {
                    $0.session == replacement.rawValue ? $0 : nil
                }
                restoreSession(replacement, snapshot: recoveredSnapshot, contextMatches: false)
                processPendingResult()
                refreshLiveState(for: replacement.rawValue)
            } else {
                requireHandoffCancellation(replacement)
            }
            return
        case .none: break
        }
        let token = SessionToken()
        deferredTerminalToken = nil
        failedHandoffRetryToken = nil
        let launchMode: KeyboardSessionLaunchMode = DarwinBridge.canStartInPlace() ? .inPlace : .manualOpen
        let before = textDocumentProxy.documentContextBeforeInput
        let after = textDocumentProxy.documentContextAfterInput
        let selection = textDocumentProxy.selectedText
        pendingKbType = textDocumentProxy.keyboardType?.rawValue ?? 0
        currentSessionId = token.rawValue
        currentExtensionSessionToken = token
        currentLivePhase = .starting
        recoveredSnapshot = KeyboardSessionRecoveryStore.save(
            session: token.rawValue, launchMode: launchMode,
            contextBefore: before, contextAfter: after, selectedText: selection
        )
        let settings = DictationSettings(
            language: LanguageManager.shared.currentLanguage.id,
            whisper: isWhisperMode,
            translateEnabled: TranslationManager.shared.translationEnabled,
            translateTarget: TranslationManager.shared.targetLanguageID,
            selectedText: selection, keyboardType: pendingKbType, session: token.rawValue,
            expectedContextFingerprint: recoveredSnapshot?.contextFingerprint
        )
        currentDictationSettings = settings
        guard DarwinBridge.writeDictationSettings(settings) else {
            resetWaitingState(message: "无法访问共享数据，请点麦克风重试", discardPendingSettings: false)
            return
        }
        guard configureSessionObservers(for: token.rawValue) else {
            resetWaitingState(message: "无法创建安全的语音会话，请点麦克风重试")
            return
        }
        isWaitingForResult = true
        liveTextLabel.text = "正在连接 VoType..."
        updateQuickTypeStatus("正在连接 VoType...", phase: .starting)
        let config = UIImage.SymbolConfiguration(pointSize: 34, weight: .bold)
        micButton.setImage(UIImage(systemName: "ellipsis", withConfiguration: config), for: .normal)
        micButton.backgroundColor = .systemOrange
        micButton.isEnabled = true
        micButton.accessibilityLabel = "正在连接 VoType"
        startResultTimeout(for: token.rawValue, interval: 65)
        startLiveStatePolling(for: token.rawValue)

        if DictationLaunchPolicy.initialAction(canStartInPlace: launchMode == .inPlace) == .requestInPlace {
            hotAckCoordinator.arm(token: token) { [weak self] expiredToken in
                self?.handoffTimedOutHotRequest(expiredToken)
            }
            DarwinBridge.postNotification(DarwinNotificationName.requestStartDictation)
        } else {
            showManualOpenFallback(sessionId: token.rawValue)
        }
    }

    private func handoffTimedOutHotRequest(_ oldToken: SessionToken) {
        guard currentSessionId == oldToken.rawValue, isWaitingForResult,
              let original = currentDictationSettings, original.session == oldToken.rawValue else { return }
        let manualToken = SessionToken()
        switch DarwinBridge.handoffDictationSettingsToManual(from: oldToken, to: manualToken, original: original) {
        case .moved(let replacement):
            _ = KeyboardSessionRecoveryStore.rebindForManualHandoff(from: oldToken, to: manualToken)
            finishWaitingState()
            currentSessionId = manualToken.rawValue
            currentDictationSettings = replacement
            currentExtensionSessionToken = nil
            // Only bind the exact rebound snapshot; missing evidence always holds.
            recoveredSnapshot = KeyboardSessionRecoveryStore.load().flatMap {
                $0.session == manualToken.rawValue ? $0 : nil
            }
            isWaitingForResult = true
            _ = configureSessionObservers(for: manualToken.rawValue)
            startResultTimeout(for: manualToken.rawValue, interval: 65)
            startLiveStatePolling(for: manualToken.rawValue)
            showManualOpenFallback(sessionId: manualToken.rawValue)
        case .alreadyTerminal:
            _ = KeyboardSessionRecoveryStore.markManualOpen(session: oldToken.rawValue)
            recoveredSnapshot = KeyboardSessionRecoveryStore.load().flatMap {
                $0.session == oldToken.rawValue ? $0 : nil
            }
            currentExtensionSessionToken = nil
            processTerminalResult(for: oldToken)
        case .unresolved(let replacement):
            requireHandoffCancellation(replacement)
        case .failed:
            currentExtensionSessionToken = nil
            failedHandoffRetryToken = oldToken
            resultTimeoutTimer?.invalidate()
            resultTimeoutTimer = nil
            // Keep polling for a terminal, but only an explicit tap may cancel/retry.
            showFailedHandoffRetry()
        }
    }

    private func requireHandoffCancellation(_ token: SessionToken) {
        finishWaitingState()
        currentSessionId = token.rawValue
        currentExtensionSessionToken = nil
        currentDictationSettings = nil
        recoveredSnapshot = KeyboardSessionRecoveryStore.load().flatMap {
            $0.session == token.rawValue ? $0 : nil
        }
        isWaitingForResult = true
        failedHandoffRetryToken = token
        _ = configureSessionObservers(for: token.rawValue)
        startLiveStatePolling(for: token.rawValue)
        showFailedHandoffRetry(message: "旧请求状态尚未确认，请点麦克风取消后重试")
    }

    private func showRecoveryStorageUnavailable() {
        finishWaitingState()
        currentSessionId = nil
        currentExtensionSessionToken = nil
        currentDictationSettings = nil
        recoveredSnapshot = nil
        // Do not clear the persisted snapshot or anchors while their storage is unknown.
        liveTextLabel.text = "暂时无法读取会话状态，请点麦克风重试"
        updateQuickTypeStatus(liveTextLabel.text ?? "请重试", phase: nil)
        micButton.isEnabled = true
        micButton.accessibilityLabel = "会话状态不可用，点按重试"
    }

    private func showFailedHandoffRetry(message: String = "无法安全切换到前台，请点麦克风重试") {
        guard let token = failedHandoffRetryToken,
              currentSessionId == token.rawValue, isWaitingForResult else { return }
        liveTextLabel.text = message
        updateQuickTypeStatus(message, phase: nil)
        let config = UIImage.SymbolConfiguration(pointSize: 34, weight: .bold)
        micButton.setImage(UIImage(systemName: "arrow.clockwise", withConfiguration: config), for: .normal)
        micButton.isEnabled = true
        micButton.backgroundColor = .systemOrange
        micButton.accessibilityLabel = "语音连接失败，点按重试"
        stopPulse()
    }

    private func showManualOpenFallback(sessionId: String) {
        hotAckCoordinator.cancel()
        guard isWaitingForResult, currentSessionId == sessionId else { return }
        currentLivePhase = .starting
        liveTextLabel.text = "请从主屏幕打开 VoType，返回后继续"
        updateQuickTypeStatus(liveTextLabel.text ?? "请手动打开 VoType", phase: .starting)
        micButton.backgroundColor = .systemOrange
        micButton.accessibilityLabel = "请从主屏幕打开 VoType"
        stopPulse()
    }

    // MARK: - Darwin 通知回调

    private func onDictationStarted(sessionId: String) {
        guard currentSessionId == sessionId, isWaitingForResult,
              let token = SessionToken(rawValue: sessionId) else { return }
        _ = hotAckCoordinator.acknowledge(token: token)
        // started acknowledges admission; only a live listening state proves microphone capture.
        refreshLiveState(for: sessionId)
    }

    private func onDictationFailed(sessionId: String) {
        guard isWaitingForResult, currentSessionId == sessionId else { return }
        hotAckCoordinator.cancel()
        currentExtensionSessionToken = nil
        guard let token = SessionToken(rawValue: sessionId) else { return }
        processTerminalResult(for: token)
    }

    private func refreshLiveState(for sessionId: String) {
        guard keyboardIsVisible,
              isWaitingForResult,
              currentSessionId == sessionId else { return }

        processPendingResult()
        guard isWaitingForResult, currentSessionId == sessionId else { return }
        if failedHandoffRetryToken?.rawValue == sessionId {
            showFailedHandoffRetry()
            return
        }

        let hasSafeContext = hasSafeRecoveryContext(for: sessionId)
        if requiresContextRevalidation, hasSafeContext {
            requiresContextRevalidation = false
        }

        if let state = DarwinBridge.readLiveState(expectedSession: sessionId) {
            let phaseChanged = currentLivePhase != state.phase
            currentLivePhase = state.phase
            if phaseChanged {
                switch state.phase {
                case .starting:
                    startResultTimeout(for: sessionId, interval: 65)
                case .listening:
                    startResultTimeout(for: sessionId, interval: 5 * 60)
                case .processing:
                    startResultTimeout(for: sessionId, interval: 90)
                }
            }
            switch state.phase {
            case .starting:
                liveTextLabel.text = requiresContextRevalidation
                    ? "会话进行中，请回到发起录音的输入框"
                    : "正在连接 VoType..."
                micButton.backgroundColor = .systemOrange
                micButton.isEnabled = true
                micButton.accessibilityLabel = "正在连接 VoType"
                stopPulse()
            case .listening:
                let partial = state.partialTranscript.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                liveTextLabel.text = requiresContextRevalidation
                    ? "正在聆听；点此可结束录音"
                    : partial.isEmpty
                    ? "正在聆听... 再点麦克风结束"
                    : partial
                let config = UIImage.SymbolConfiguration(pointSize: 34, weight: .bold)
                micButton.setImage(
                    UIImage(systemName: "stop.fill", withConfiguration: config),
                    for: .normal
                )
                micButton.backgroundColor = .systemRed
                micButton.isEnabled = true
                micButton.accessibilityLabel = "正在聆听，点按结束"
                startPulse()
            case .processing:
                liveTextLabel.text = requiresContextRevalidation
                    ? "正在整理文字；结果需确认后插入"
                    : state.partialTranscript.isEmpty
                    ? "正在整理文字..."
                    : "正在整理：\(String(state.partialTranscript.prefix(48)))"
                micButton.isEnabled = false
                micButton.backgroundColor = .systemGray
                micButton.accessibilityLabel = "正在整理文字"
                stopPulse()
            }
            updateQuickTypeStatus(
                liveTextLabel.text ?? "语音输入",
                phase: state.phase
            )
        }

        // Darwin 通知只是提示；每次刷新都顺便检查终态文件，避免丢通知。
        processPendingResult()
    }

    private func startLiveStatePolling(for sessionId: String) {
        liveStatePollTimer?.invalidate()
        liveStatePollTimer = Timer.scheduledTimer(
            withTimeInterval: 0.5,
            repeats: true
        ) { [weak self] _ in
            self?.refreshLiveState(for: sessionId)
        }
    }

    /// 恢复麦克风按钮到默认状态 (录音结束/结果插入后调用)
    private func restoreMicButton() {
        let config = UIImage.SymbolConfiguration(pointSize: 34, weight: .bold)
        let canStartHere = DarwinBridge.canStartInPlace()
        micButton.setImage(
            UIImage(
                systemName: canStartHere ? "mic.fill" : "mic",
                withConfiguration: config
            ),
            for: .normal
        )
        micButton.backgroundColor = UIColor.systemBlue
        micButton.isEnabled = true
        micButton.accessibilityLabel = canStartHere
            ? "语音输入，已待命，可原地开始"
            : "语音输入，需要打开 VoType"
        stopPulse()
    }

    private func startReadinessPolling() {
        readinessPollTimer?.invalidate()
        updateReadinessAppearance()
        readinessPollTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: true
        ) { [weak self] _ in
            self?.updateReadinessAppearance()
        }
    }

    private func updateReadinessAppearance() {
        guard keyboardIsVisible,
              !isWaitingForResult,
              currentHeldSession == nil else { return }
        restoreMicButton()
        let message = DarwinBridge.canStartInPlace()
            ? "已待命，点实心麦克风原地说话"
            : "点空心麦克风，请手动打开 VoType 后继续"
        if liveTextLabel.text == "点击麦克风开始语音输入"
            || liveTextLabel.text?.hasPrefix("已待命") == true
            || liveTextLabel.text?.hasPrefix("点空心") == true {
            liveTextLabel.text = message
        }
    }

    // MARK: - 处理识别结果

    /// Recreated extensions never inherit ownership of an automatic insertion.
    private func checkForPendingResult() {
        guard keyboardIsVisible, currentHeldSession == nil else { return }
        if isWaitingForResult, let session = currentSessionId {
            processPendingResult()
            refreshLiveState(for: session)
            return
        }
        let snapshot = KeyboardSessionRecoveryStore.load()
        let before = textDocumentProxy.documentContextBeforeInput
        let after = textDocumentProxy.documentContextAfterInput
        let selection = textDocumentProxy.selectedText
        let matches = snapshot.map {
            KeyboardSessionRecoveryStore.matches($0, contextBefore: before, contextAfter: after, selectedText: selection)
        } ?? false
        switch KeyboardSessionRecoveryStore.recoveryDecision(snapshot: snapshot, contextMatches: matches) {
        case .restore(let token):
            recoveredSnapshot = snapshot.flatMap { $0.session == token.rawValue ? $0 : nil }
            restoreSession(token, snapshot: recoveredSnapshot, contextMatches: matches)
            processPendingResult()
            refreshLiveState(for: token.rawValue)
        case .retry(let token):
            currentSessionId = token.rawValue
            finishSession(session: token.rawValue, message: "旧会话无法继续，请点麦克风重试")
        case .cancelBeforeRetry(let token):
            requireHandoffCancellation(token)
        case .storageUnavailable:
            showRecoveryStorageUnavailable()
        case .none:
            recoveredSnapshot = nil
        }
    }

    private enum PendingResultHandling {
        case handled, missing, deferredHidden
    }

    private func processTerminalResult(for token: SessionToken) {
        guard currentSessionId == token.rawValue, isWaitingForResult else { return }
        deferredTerminalToken = token
        resultTimeoutTimer?.invalidate()
        resultTimeoutTimer = nil
        processPendingResult()
    }

    @discardableResult
    private func processPendingResult() -> PendingResultHandling {
        guard keyboardIsVisible else { return .deferredHidden }
        guard isWaitingForResult,
              let session = currentSessionId,
              let token = SessionToken(rawValue: session) else { return .missing }
        guard let pending = DarwinBridge.peekResult(expectedSession: token.rawValue),
              SessionToken(rawValue: pending.session) == token else {
            if deferredTerminalToken == token {
                finishSession(session: session, message: "旧会话已结束，结果不可用，请点麦克风重试")
            }
            return .missing
        }
        hotAckCoordinator.cancel()
        if pending.status == .error {
            completeTerminalError(pending)
            return .handled
        }
        guard let plan = pending.editPlan else {
            holdResult(pending, message: "无法确认结果操作，可复制或丢弃")
            return .handled
        }
        // Snapshot all three proxy values once. No proxy reads after validation.
        let before = textDocumentProxy.documentContextBeforeInput
        let after = textDocumentProxy.documentContextAfterInput
        let selection = textDocumentProxy.selectedText
        let matches = matchesRecoveredContext(session: session, before: before, after: after, selection: selection)
        let disposition = KeyboardResultDispositionPolicy.decide(
            launchMode: recoveredSnapshot?.launchMode ?? .manualOpen,
            belongsToCurrentExtensionInstance: currentExtensionSessionToken == token,
            currentSelectedText: selection,
            hasContextEvidence: recoveredSnapshot?.hasContextEvidence ?? false,
            contextMatches: matches, operation: plan.operation,
            requiresConfirmation: plan.requiresConfirmation
        )
        guard disposition == .autoInsert, !plan.text.isEmpty else {
            let selectedInsert = selection?.isEmpty == false
                && (plan.operation == .insertAtCursor || plan.operation == .previewOnly)
            holdResult(pending, message: selectedInsert
                ? "当前有选中文本，未覆盖原文。请取消选区后插入，或复制结果。"
                : "结果已就绪，请选择插入、复制或丢弃")
            return .handled
        }
        guard let consumed = DarwinBridge.readAndConsumeResult(expectedSession: token.rawValue),
              KeyboardHeldEditValidator.consumedResultMatchesPreview(previewed: pending, consumed: consumed) else {
            finishSession(session: session, message: "结果已变化或由其他键盘窗口处理，请点麦克风重试")
            return .handled
        }
        textDocumentProxy.insertText(plan.text)
        finishSession(session: session, message: "已输入 ✓")
        return .handled
    }

    private func matchesRecoveredContext(session: String, before: String?, after: String?, selection: String?) -> Bool {
        guard let snapshot = recoveredSnapshot,
              let snapshotToken = SessionToken(rawValue: snapshot.session),
              snapshotToken.rawValue == session,
              snapshot.hasContextEvidence else { return false }
        return KeyboardSessionRecoveryStore.matches(
            snapshot, contextBefore: before, contextAfter: after, selectedText: selection
        )
    }

    private func hasSafeRecoveryContext(for session: String) -> Bool {
        let before = textDocumentProxy.documentContextBeforeInput
        let after = textDocumentProxy.documentContextAfterInput
        let selection = textDocumentProxy.selectedText
        return matchesRecoveredContext(session: session, before: before, after: after, selection: selection)
    }

    private func holdResult(_ result: DictationIPCResult, message: String) {
        guard SessionToken(rawValue: result.session) != nil else {
            showHeldResultMessage("结果会话无效，未修改原文")
            return
        }
        finishWaitingState()
        currentHeldSession = result.session
        heldResultPreview = result
        currentSessionId = result.session
        currentExtensionSessionToken = nil
        currentDictationSettings = nil
        heldResultActionView.isHidden = false
        symbolBar.isHidden = true
        showVoiceInput()
        micButton.backgroundColor = .systemGreen
        micButton.accessibilityLabel = "结果待确认，请选择插入、复制或丢弃"
        showHeldResultMessage(message)
    }

    private func showHeldResultMessage(_ message: String) {
        let text = heldResultPreview?.editPlan?.text ?? ""
        liveTextLabel.text = text.isEmpty ? message : message + "\n" + text
        updateQuickTypeStatus(message, phase: nil)
    }

    /// The preview is frozen when displayed. A tap cannot silently adopt a changed payload.
    private func validatedHeldPreview() -> (SessionToken, DictationIPCResult)? {
        guard let held = currentHeldSession.flatMap(SessionToken.init(rawValue:)),
              let preview = heldResultPreview,
              let previewToken = SessionToken(rawValue: preview.session),
              previewToken == held else {
            showHeldResultMessage("结果会话无效，未修改原文")
            return nil
        }
        guard let pending = DarwinBridge.peekResult(expectedSession: held.rawValue) else {
            finishSession(session: held.rawValue, message: "结果已过期或由其他键盘窗口处理，请点麦克风重试")
            return nil
        }
        guard pending == preview else {
            showHeldResultMessage("结果已变化，未修改原文")
            return nil
        }
        return (held, preview)
    }

    private func insertHeldResult() {
        guard let (token, preview) = validatedHeldPreview(), let plan = preview.editPlan else { return }
        let snapshotToken = recoveredSnapshot.flatMap { SessionToken(rawValue: $0.session) }
        let before = textDocumentProxy.documentContextBeforeInput
        let after = textDocumentProxy.documentContextAfterInput
        let selection = textDocumentProxy.selectedText
        let application = KeyboardHeldEditValidator.decide(
            plan: plan, previewedToken: token, heldToken: token,
            snapshotToken: snapshotToken, snapshotFingerprint: recoveredSnapshot?.contextFingerprint,
            hasContextEvidence: recoveredSnapshot?.hasContextEvidence ?? false,
            contextMatches: matchesRecoveredContext(session: token.rawValue, before: before, after: after, selection: selection),
            currentSelectedText: selection
        )
        guard application != .reject else {
            let selectedInsert = selection?.isEmpty == false
                && (plan.operation == .insertAtCursor || plan.operation == .previewOnly)
            showHeldResultMessage(selectedInsert
                ? "当前有选中文本，未覆盖原文。请取消选区后插入，或复制结果。"
                : "选区或输入位置已变化，未修改原文")
            return
        }
        guard let consumed = DarwinBridge.readAndConsumeResult(expectedSession: token.rawValue),
              KeyboardHeldEditValidator.consumedResultMatchesPreview(previewed: preview, consumed: consumed) else {
            finishSession(session: token.rawValue, message: "结果已变化或由其他键盘窗口处理，请点麦克风重试")
            return
        }
        // Synchronous main-thread mutation with the already validated selection.
        switch application {
        case .insertAtCursor(let text):
            textDocumentProxy.insertText(text)
        case .replaceSelection(let text):
            textDocumentProxy.deleteBackward()
            textDocumentProxy.insertText(text)
        case .deleteSelection:
            textDocumentProxy.deleteBackward()
        case .reject:
            assertionFailure("Rejected edit cannot reach document mutation")
            return
        }
        finishSession(session: token.rawValue, message: application == .deleteSelection ? "已删除选中文本 ✓" : "已输入 ✓")
    }

    private func copyHeldResult() {
        guard let (token, preview) = validatedHeldPreview() else { return }
        guard let text = preview.editPlan?.text, !text.isEmpty else {
            showHeldResultMessage("没有可复制的文字，可选择丢弃")
            return
        }
        guard let consumed = DarwinBridge.readAndConsumeResult(expectedSession: token.rawValue),
              KeyboardHeldEditValidator.consumedResultMatchesPreview(previewed: preview, consumed: consumed) else {
            finishSession(session: token.rawValue, message: "结果已变化或由其他键盘窗口处理，请点麦克风重试")
            return
        }
        UIPasteboard.general.string = text
        finishSession(session: token.rawValue, message: "已复制结果 ✓")
    }

    private func discardHeldResult() {
        guard let (token, _) = validatedHeldPreview() else { return }
        guard DarwinBridge.readAndConsumeResult(expectedSession: token.rawValue) != nil else {
            finishSession(session: token.rawValue, message: "结果已由其他键盘窗口处理，请点麦克风重试")
            return
        }
        finishSession(session: token.rawValue, message: "已丢弃结果")
    }

    private func completeTerminalError(_ pending: DictationIPCResult) {
        guard let token = SessionToken(rawValue: pending.session),
              currentSessionId == token.rawValue, pending.status == .error else { return }
        currentExtensionSessionToken = nil
        hotAckCoordinator.cancel()
        guard let consumed = DarwinBridge.readAndConsumeResult(expectedSession: token.rawValue),
              consumed == pending else {
            finishSession(session: token.rawValue, message: "结果已变化或由其他键盘窗口处理，请点麦克风重试")
            return
        }
        // Consume only the old failure; its terminal receipt remains authoritative.
        finishSession(session: token.rawValue, message: pending.text + "，请点麦克风重试")
    }

    private func restoreSession(_ token: SessionToken, snapshot: KeyboardSessionRecoverySnapshot?, contextMatches: Bool) {
        let session = token.rawValue
        hotAckCoordinator.cancel()
        failedHandoffRetryToken = nil
        deferredTerminalToken = nil
        currentSessionId = session
        currentExtensionSessionToken = nil
        currentDictationSettings = nil
        isWaitingForResult = true
        requiresContextRevalidation = !(snapshot?.hasContextEvidence == true && contextMatches)
        _ = configureSessionObservers(for: session)
        startResultTimeout(for: session, interval: 65)
        startLiveStatePolling(for: session)
        if let state = DarwinBridge.readLiveState(expectedSession: session) {
            currentLivePhase = state.phase
            switch state.phase {
            case .starting: break
            case .listening: startResultTimeout(for: session, interval: 5 * 60)
            case .processing: startResultTimeout(for: session, interval: 90)
            }
        } else {
            currentLivePhase = .starting
            if DarwinBridge.peekDictationSettings(expectedSession: session) != nil {
                showManualOpenFallback(sessionId: session)
            } else {
                liveTextLabel.text = "正在等待 VoType..."
            }
        }
    }

    private func finishWaitingState() {
        isWaitingForResult = false
        hotAckCoordinator.cancel()
        failedHandoffRetryToken = nil
        deferredTerminalToken = nil
        resultTimeoutTimer?.invalidate()
        resultTimeoutTimer = nil
        liveStatePollTimer?.invalidate()
        liveStatePollTimer = nil
        dictationStartedObserver = nil
        dictationFailedObserver = nil
        liveStateChangedObserver = nil
        currentLivePhase = nil
        requiresContextRevalidation = false
        restoreMicButton()
    }

    private func finishSession(session: String, message: String) {
        guard currentSessionId == session || currentHeldSession == session else { return }
        finishWaitingState()
        KeyboardSessionRecoveryStore.clear(expectedSession: session)
        currentSessionId = nil
        currentHeldSession = nil
        heldResultPreview = nil
        currentExtensionSessionToken = nil
        currentDictationSettings = nil
        recoveredSnapshot = nil
        heldResultActionView.isHidden = true
        symbolBar.isHidden = false
        liveTextLabel.text = message
        updateQuickTypeStatus(message, phase: nil)
    }

    private func resetWaitingState(message: String, discardPendingSettings: Bool = true) {
        guard let session = currentSessionId else {
            finishWaitingState()
            currentExtensionSessionToken = nil
            currentDictationSettings = nil
            liveTextLabel.text = message
            updateQuickTypeStatus(message, phase: nil)
            return
        }
        if discardPendingSettings {
            guard DarwinBridge.cancelSession(session) else {
                liveTextLabel.text = "无法确认取消，正在保留会话以防结果丢失"
                updateQuickTypeStatus(liveTextLabel.text ?? "请重试", phase: currentLivePhase)
                return
            }
            DarwinBridge.postSessionNotification(base: DarwinNotificationName.requestCancelDictation, session: session)
        }
        finishSession(session: session, message: message)
    }

    private func startResultTimeout(for session: String, interval: TimeInterval) {
        resultTimeoutTimer?.invalidate()
        let generation = UUID()
        resultTimeoutGeneration = generation
        resultTimeoutTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isWaitingForResult, self.currentSessionId == session,
                      self.resultTimeoutTimer != nil, self.resultTimeoutGeneration == generation else { return }
                self.processPendingResult()
                guard self.isWaitingForResult, self.currentSessionId == session else { return }
                // A hidden keyboard defers presentation, never discards a ready result on timeout.
                if DarwinBridge.peekResult(expectedSession: session) != nil {
                    self.hotAckCoordinator.cancel()
                    return
                }
                guard DarwinBridge.cancelSession(session) else {
                    self.liveTextLabel.text = "取消确认失败，继续等待结果"
                    self.updateQuickTypeStatus("取消确认失败，继续等待结果", phase: self.currentLivePhase)
                    self.startResultTimeout(for: session, interval: 15)
                    return
                }
                DarwinBridge.postSessionNotification(base: DarwinNotificationName.requestCancelDictation, session: session)
                self.resetWaitingState(message: "语音输入超时，请点麦克风重试", discardPendingSettings: false)
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
