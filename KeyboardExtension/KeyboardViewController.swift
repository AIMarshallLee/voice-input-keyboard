import UIKit

/// 语音输入键盘 - Darwin 通知 + 命名剪贴板 IPC 架构 (Build 16)
/// iOS 键盘扩展无法直接录音(平台限制)
///
/// 启动路径: 键盘先把会话写入 App Group，再从用户的麦克风点击打开
/// VoType。宿主前台消费同一会话，录音开始后用户可立即返回原输入框。
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
    private var darwinFallbackTimer: Timer?
    private var resultTimeoutTimer: Timer?
    private var liveStatePollTimer: Timer?
    private var readinessPollTimer: Timer?
    private var recoveredPendingSessionId: String?
    private var recoveredSnapshot: KeyboardSessionRecoverySnapshot?
    private var currentLivePhase: DictationLivePhase?
    private var keyboardIsVisible = false
    private var requiresContextRevalidation = false

    // 暂存启动时的设置,处理结果时使用
    private var pendingSelectedText: String?
    private var pendingKbType: Int = 0

    // MARK: - 模式状态
    private var isWhisperMode = false
    private var selectedTextBeforeRecording: String?

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
        darwinFallbackTimer?.invalidate()
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

        if recoveredPendingSessionId != nil {
            confirmRecoveredResult()
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
                    base: DarwinNotificationName.requestStopDictation,
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

    /// 先写入完整会话并通知仍在运行的宿主，然后用这次明确的用户点击
    /// 请求打开 VoType。这样宿主无论运行、挂起还是已终止都能消费同一会话。
    private func launchDictation() {
        guard hasFullAccess else {
            liveTextLabel.text = "请到设置→键盘→VoType→开启「允许完全访问」"
            return
        }

        let sessionId = UUID().uuidString
        currentSessionId = sessionId
        currentLivePhase = .starting

        selectedTextBeforeRecording = textDocumentProxy.selectedText
        pendingSelectedText = selectedTextBeforeRecording
        pendingKbType = textDocumentProxy.keyboardType?.rawValue ?? 0
        recoveredSnapshot = KeyboardSessionRecoveryStore.save(
            session: sessionId,
            contextBefore: textDocumentProxy.documentContextBeforeInput,
            contextAfter: textDocumentProxy.documentContextAfterInput,
            selectedText: selectedTextBeforeRecording
        )

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
            resetWaitingState(
                message: "无法访问共享数据，请检查 App Group 配置",
                discardPendingSettings: false
            )
            return
        }
        guard configureSessionObservers(for: sessionId) else {
            resetWaitingState(message: "无法创建安全的语音会话")
            return
        }

        isWaitingForResult = true
        recoveredPendingSessionId = nil
        liveTextLabel.text = "正在连接 VoType..."
        updateQuickTypeStatus("正在连接 VoType...", phase: .starting)
        micButton.isEnabled = true
        startResultTimeout(for: sessionId, interval: 65)
        startLiveStatePolling(for: sessionId)

        // 麦克风按钮变声纹图标
        let waveConfig = UIImage.SymbolConfiguration(pointSize: 34, weight: .bold)
        micButton.setImage(UIImage(systemName: "ellipsis", withConfiguration: waveConfig), for: .normal)
        micButton.backgroundColor = UIColor.systemOrange
        micButton.accessibilityLabel = "正在连接 VoType"

        // 热路径会先尝试原地启动，1.2 秒没有 started 才降级到冷启动；
        // 整条路径必须给出明确状态，不再永远停在“打开后即可说话”。
        // 收到 dictationStarted 会取消此 timer
        // 收到 dictationFailed 也会取消此 timer 并降级
        darwinFallbackTimer = Timer.scheduledTimer(
            withTimeInterval: DictationLaunchPolicy.manualRecoveryDeadline,
            repeats: false
        ) { [weak self] _ in
            guard let self = self, self.isWaitingForResult else { return }
            print("[KB] No supported background response; asking user to open VoType")
            self.showManualOpenFallback(sessionId: sessionId)
        }

        routeDictationStart(sessionId: sessionId)
    }

    private func routeDictationStart(sessionId: String) {
        let initialAction = DictationLaunchPolicy.initialAction(
            canStartInPlace: DarwinBridge.canStartInPlace()
        )
        guard initialAction == .requestInPlace else {
            liveTextLabel.text = "正在打开 VoType…"
            updateQuickTypeStatus("正在打开 VoType…", phase: .starting)
            requestContainingAppOpen(sessionId: sessionId)
            return
        }

        liveTextLabel.text = "已连接待命服务，正在开麦…"
        updateQuickTypeStatus("已连接待命服务，正在开麦…", phase: .starting)
        DarwinBridge.postNotification(DarwinNotificationName.requestStartDictation)

        DispatchQueue.main.asyncAfter(
            deadline: .now() + DictationLaunchPolicy.inPlaceResponseDeadline
        ) { [weak self] in
            guard let self,
                  self.keyboardIsVisible,
                  self.isWaitingForResult,
                  self.currentSessionId == sessionId,
                  self.currentLivePhase == .starting else { return }
            self.liveTextLabel.text = "待命响应超时，正在打开 VoType…"
            self.updateQuickTypeStatus(
                "待命响应超时，正在打开 VoType…",
                phase: .starting
            )
            self.requestContainingAppOpen(sessionId: sessionId)
        }
    }

    /// Apple does not guarantee `NSExtensionContext.open` for custom keyboards.
    /// Run the responder-chain request immediately from the user's tap instead
    /// of trusting the extension-context completion value, then retry only while
    /// the keyboard is still visible and the same session is waiting.
    private func requestContainingAppOpen(sessionId: String) {
        guard let url = DictationConstants.buildDictationURL(session: sessionId) else {
            showManualOpenFallback(sessionId: sessionId)
            return
        }

        // Build 112 tried extensionContext first. On the tested iPhone it could
        // report the request as accepted without actually switching apps, so the
        // responder route never ran. Do not gate the real fallback on that flag.
        _ = openURLThroughResponderChain(url)

        extensionContext?.open(url) { opened in
            print("[KB] extensionContext.open completion: \(opened)")
        }

        for delay in [0.20, 0.65] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self,
                      self.keyboardIsVisible,
                      self.isWaitingForResult,
                      self.currentSessionId == sessionId,
                      self.currentLivePhase == .starting else { return }
                print("[KB] Retrying containing-app open after \(delay)s")
                _ = self.openURLThroughResponderChain(url)
            }
        }
    }

    @discardableResult
    private func openURLThroughResponderChain(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector) {
                print("[KB] Sending openURL: through \(type(of: current))")
                current.perform(selector, with: url)
                return true
            }
            responder = current.next
        }
        print("[KB] No responder accepted openURL:")
        return false
    }

    /// 如果系统拒绝打开请求，仍保留会话；用户手动打开 VoType 后会自动消费。
    private func showManualOpenFallback(sessionId: String) {
        darwinFallbackTimer?.invalidate()
        darwinFallbackTimer = nil
        guard isWaitingForResult, currentSessionId == sessionId else { return }
        currentLivePhase = .starting
        liveTextLabel.text = "系统未允许自动打开，请从主屏幕点 VoType"
        updateQuickTypeStatus(
            "系统未允许自动打开，请从主屏幕点 VoType",
            phase: .starting
        )
        micButton.backgroundColor = .systemOrange
        micButton.accessibilityLabel = "请从主屏幕打开 VoType"
        stopPulse()
    }

    // MARK: - Darwin 通知回调

    /// 主 App 确认开始录音
    private func onDictationStarted(sessionId: String) {
        guard currentSessionId == sessionId, isWaitingForResult else { return }
        darwinFallbackTimer?.invalidate()
        darwinFallbackTimer = nil
        isWaitingForResult = true
        currentLivePhase = .listening

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.liveTextLabel.text = "正在聆听... 再点麦克风结束"
            self.updateQuickTypeStatus(
                "正在聆听... 点此结束",
                phase: .listening
            )
            // 声纹波浪图标 + 红色背景
            let waveConfig = UIImage.SymbolConfiguration(pointSize: 34, weight: .bold)
            self.micButton.setImage(UIImage(systemName: "stop.fill", withConfiguration: waveConfig), for: .normal)
            self.micButton.backgroundColor = UIColor.systemRed
            self.micButton.isEnabled = true
            self.micButton.accessibilityLabel = "正在聆听，点按结束"
            self.startPulse()
        }
    }

    /// 主 App 后台识别失败 → 提示用户打开前台录音页。
    private func onDictationFailed(sessionId: String) {
        guard isWaitingForResult, currentSessionId == sessionId else { return }
        print("[KB] Background recognition failed; foreground handoff required")
        darwinFallbackTimer?.invalidate()
        darwinFallbackTimer = nil
        liveTextLabel.text = "原地录音未启动，正在打开 VoType…"
        updateQuickTypeStatus(
            "原地录音未启动，正在打开 VoType…",
            phase: .starting
        )
        requestContainingAppOpen(sessionId: sessionId)
        darwinFallbackTimer = Timer.scheduledTimer(
            withTimeInterval: 1.8,
            repeats: false
        ) { [weak self] _ in
            self?.showManualOpenFallback(sessionId: sessionId)
        }
    }

    private func refreshLiveState(for sessionId: String) {
        guard keyboardIsVisible,
              isWaitingForResult,
              currentSessionId == sessionId else { return }

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
              recoveredPendingSessionId == nil else { return }
        restoreMicButton()
        let message = DarwinBridge.canStartInPlace()
            ? "已待命，点实心麦克风原地说话"
            : "点空心麦克风，VoType 将短暂打开"
        if liveTextLabel.text == "点击麦克风开始语音输入"
            || liveTextLabel.text?.hasPrefix("已待命") == true
            || liveTextLabel.text?.hasPrefix("点空心") == true {
            liveTextLabel.text = message
        }
    }

    // MARK: - 处理识别结果

    /// 扩展重建后用会话快照恢复。只有输入框上下文哈希仍匹配、结果不涉及
    /// 删除选区时才自动插入；空输入框或破坏性编辑仍要求用户明确确认。
    private func checkForPendingResult() {
        if isWaitingForResult, let session = currentSessionId {
            processPendingResult()
            refreshLiveState(for: session)
            return
        }

        if let snapshot = KeyboardSessionRecoveryStore.load() {
            recoveredSnapshot = snapshot
            let contextMatches = KeyboardSessionRecoveryStore.matches(
                snapshot,
                contextBefore: textDocumentProxy.documentContextBeforeInput,
                contextAfter: textDocumentProxy.documentContextAfterInput,
                selectedText: textDocumentProxy.selectedText
            )

            if let pending = DarwinBridge.peekResult(
                expectedSession: snapshot.session
            ) {
                if pending.status == .error
                    || (!pending.deleteSelected
                        && snapshot.hasContextEvidence
                        && contextMatches) {
                    restoreSession(snapshot, contextMatches: contextMatches)
                    processPendingResult()
                    return
                }

                recoveredPendingSessionId = pending.session
                liveTextLabel.text = pending.deleteSelected
                    ? "语音编辑结果已就绪，再点麦克风确认"
                    : "结果已就绪，再点麦克风插入"
                restoreMicButton()
                micButton.backgroundColor = .systemGreen
                updateQuickTypeStatus(liveTextLabel.text ?? "结果已就绪", phase: nil)
                return
            }

            if DarwinBridge.readLiveState(expectedSession: snapshot.session) != nil
                || DarwinBridge.peekPendingDictationSettings()?.session == snapshot.session {
                restoreSession(snapshot, contextMatches: contextMatches)
                refreshLiveState(for: snapshot.session)
                return
            }

            // live 快照可能在长听写期间过期，但恢复快照仍能证明当前输入框
            // 没有变化。重新接上同一 session，终态通知即使丢失也会被轮询发现。
            if snapshot.hasContextEvidence, contextMatches {
                restoreSession(snapshot, contextMatches: true)
                refreshLiveState(for: snapshot.session)
                return
            }
        }

        guard let pending = DarwinBridge.peekResult() else { return }
        recoveredPendingSessionId = pending.session
        liveTextLabel.text = pending.status == .completed
            ? "检测到待插入结果，再点麦克风确认"
            : "检测到语音输入状态，再点麦克风查看"
        restoreMicButton()
        micButton.backgroundColor = .systemGreen
        updateQuickTypeStatus(liveTextLabel.text ?? "结果已就绪", phase: nil)
    }

    private func confirmRecoveredResult() {
        guard let session = recoveredPendingSessionId else { return }
        guard let pending = DarwinBridge.peekResult(expectedSession: session) else {
            recoveredPendingSessionId = nil
            restoreMicButton()
            liveTextLabel.text = "待插入结果已过期，请重新录音"
            return
        }

        if pending.deleteSelected {
            guard let snapshot = recoveredSnapshot,
                  snapshot.session == session,
                  snapshot.hasContextEvidence,
                  KeyboardSessionRecoveryStore.matches(
                      snapshot,
                      contextBefore: textDocumentProxy.documentContextBeforeInput,
                      contextAfter: textDocumentProxy.documentContextAfterInput,
                      selectedText: textDocumentProxy.selectedText
                  ),
                  let selectedText = textDocumentProxy.selectedText,
                  !selectedText.isEmpty else {
                liveTextLabel.text = "选区已变化，结果未插入，请重新录音"
                return
            }
            pendingSelectedText = selectedText
        }

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
        guard keyboardIsVisible,
              isWaitingForResult,
              let session = currentSessionId else { return }
        guard let pending = DarwinBridge.peekResult(expectedSession: session) else {
            // session 不匹配或尚未写完时绝不消费现有文件。
            return
        }
        if pending.status == .completed,
           requiresContextRevalidation,
           !hasSafeRecoveryContext(for: session) {
            recoveredPendingSessionId = session
            finishWaitingState()
            liveTextLabel.text = pending.deleteSelected
                ? "输入位置已变化，点麦克风核对编辑结果"
                : "结果已就绪，点麦克风确认插入"
            micButton.backgroundColor = .systemGreen
            updateQuickTypeStatus(liveTextLabel.text ?? "结果已就绪", phase: nil)
            return
        }
        guard let result = DarwinBridge.readAndConsumeResult(expectedSession: session) else {
            return
        }
        finishWaitingState()
        handle(result)
    }

    private func hasSafeRecoveryContext(for session: String) -> Bool {
        guard let snapshot = recoveredSnapshot,
              snapshot.session == session,
              snapshot.hasContextEvidence else { return false }
        return KeyboardSessionRecoveryStore.matches(
            snapshot,
            contextBefore: textDocumentProxy.documentContextBeforeInput,
            contextAfter: textDocumentProxy.documentContextAfterInput,
            selectedText: textDocumentProxy.selectedText
        )
    }

    private func handle(_ result: DictationIPCResult) {
        if let text = result.transcription {
            insertResult(text, deleteSelected: result.deleteSelected)
        } else if let error = result.error {
            liveTextLabel.text = error
        }
        updateQuickTypeStatus(liveTextLabel.text ?? "语音输入", phase: nil)
        KeyboardSessionRecoveryStore.clear(expectedSession: result.session)
        recoveredSnapshot = nil
        recoveredPendingSessionId = nil
        pendingSelectedText = nil
        currentSessionId = nil
    }

    private func restoreSession(
        _ snapshot: KeyboardSessionRecoverySnapshot,
        contextMatches: Bool
    ) {
        currentSessionId = snapshot.session
        recoveredPendingSessionId = nil
        isWaitingForResult = true
        requiresContextRevalidation = !(snapshot.hasContextEvidence && contextMatches)
        pendingSelectedText = contextMatches ? textDocumentProxy.selectedText : nil
        _ = configureSessionObservers(for: snapshot.session)
        startResultTimeout(for: snapshot.session, interval: 65)
        startLiveStatePolling(for: snapshot.session)
        if let state = DarwinBridge.readLiveState(expectedSession: snapshot.session) {
            currentLivePhase = state.phase
            let interval: TimeInterval
            switch state.phase {
            case .starting: interval = 65
            case .listening: interval = 5 * 60
            case .processing: interval = 90
            }
            startResultTimeout(for: snapshot.session, interval: interval)
        } else {
            currentLivePhase = .starting
            liveTextLabel.text = "正在等待 VoType..."
        }
    }

    private func finishWaitingState() {
        isWaitingForResult = false
        darwinFallbackTimer?.invalidate()
        darwinFallbackTimer = nil
        resultTimeoutTimer?.invalidate()
        resultTimeoutTimer = nil
        liveStatePollTimer?.invalidate()
        liveStatePollTimer = nil
        dictationStartedObserver = nil
        dictationFailedObserver = nil
        liveStateChangedObserver = nil
        currentLivePhase = nil
        requiresContextRevalidation = false
        micButton.isEnabled = true
        restoreMicButton()
    }

    private func resetWaitingState(
        message: String,
        discardPendingSettings: Bool = true
    ) {
        let session = currentSessionId
        if discardPendingSettings, let session {
            guard DarwinBridge.cancelSession(session) else {
                liveTextLabel.text = "无法确认取消，正在保留会话以防结果丢失"
                updateQuickTypeStatus(
                    "无法确认取消，正在保留会话以防结果丢失",
                    phase: currentLivePhase
                )
                return
            }
            KeyboardSessionRecoveryStore.clear(expectedSession: session)
        }
        finishWaitingState()
        currentSessionId = nil
        recoveredPendingSessionId = nil
        recoveredSnapshot = nil
        pendingSelectedText = nil
        liveTextLabel.text = message
        updateQuickTypeStatus(message, phase: nil)
    }

    private func startResultTimeout(
        for session: String,
        interval: TimeInterval
    ) {
        resultTimeoutTimer?.invalidate()
        resultTimeoutTimer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: false
        ) { [weak self] _ in
            guard let self,
                  self.isWaitingForResult,
                  self.currentSessionId == session else { return }
            self.processPendingResult()
            guard self.isWaitingForResult,
                  self.currentSessionId == session else { return }
            guard DarwinBridge.cancelSession(session) else {
                self.liveTextLabel.text = "取消确认失败，继续等待结果"
                self.updateQuickTypeStatus(
                    "取消确认失败，继续等待结果",
                    phase: self.currentLivePhase
                )
                self.startResultTimeout(for: session, interval: 15)
                return
            }
            KeyboardSessionRecoveryStore.clear(expectedSession: session)
            DarwinBridge.postSessionNotification(
                base: DarwinNotificationName.requestStopDictation,
                session: session
            )
            self.resetWaitingState(
                message: "语音输入超时，请重试",
                discardPendingSettings: false
            )
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
