import Combine
import Foundation

/// 将键盘的热请求交给共享引擎；这里只负责会话归属、命令和 PiP 展示。
@MainActor
final class BackgroundDictationManager: ObservableObject {
    static let shared = BackgroundDictationManager(
        engine: DictationSessionEnvironment.shared.engine,
        pip: PiPStandbyManager.shared
    )

    private let engine: any DictationSessionRunning
    private let pip: any PiPStandbyPresenting
    private var startObserver: DarwinNotificationObserver?
    private var stopObserver: DarwinNotificationObserver?
    private var cancelObserver: DarwinNotificationObserver?
    private var currentToken: SessionToken?
    private var eventConsumer: Task<Void, Never>?
    private var isDraining = false
    private var needsDrain = false
    private var startingToken: SessionToken?

    var engineIdentity: ObjectIdentifier { ObjectIdentifier(engine as AnyObject) }

    init(engine: any DictationSessionRunning, pip: any PiPStandbyPresenting) {
        self.engine = engine
        self.pip = pip
        startObserver = DarwinNotificationObserver(
            name: DarwinNotificationName.requestStartDictation
        ) { [weak self] in
            Task { @MainActor in await self?.handlePendingRequest() }
        }
    }

    deinit {
        eventConsumer?.cancel()
    }

    /// 保留宿主启动入口，但不创建心跳、音频或另一份会话生命周期。
    func autoRestoreIfNeeded() {
        if !pip.isActive { DarwinBridge.clearReadiness() }
    }

    func handlePendingRequest() async {
        needsDrain = true
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        while needsDrain {
            needsDrain = false
            guard pip.isActive else {
                DarwinBridge.clearReadiness()
                return
            }
            guard let pending = DarwinBridge.peekPendingDictationSettings(),
                  let token = SessionToken(rawValue: pending.session),
                  let settings = DarwinBridge.readAndConsumeDictationSettings(
                    expectedSession: token.rawValue
                  ) else { continue }

            let request = DictationSessionRequest(
                token: token,
                entryPoint: .inPlace,
                authorizationPolicy: .readOnly,
                whisper: settings.whisper,
                processing: TextProcessingSnapshot(
                    selectedText: settings.selectedText,
                    keyboardType: settings.keyboardType,
                    language: settings.language,
                    translateEnabled: settings.translateEnabled,
                    translateTarget: settings.translateTarget,
                    voiceEditEnabled: TextProcessor.shared.voiceEditEnabled,
                    livePreviewEnabled: TextProcessor.shared.livePreviewEnabled,
                    expectedContextFingerprint: settings.expectedContextFingerprint
                )
            )

            // start 自身负责引擎内的旧会话终结。先撤销旧 consumer，避免等待时
            // 旧事件或 EOF 清除新请求；整个 drain 不允许第二个 start 并发进入。
            detachCurrentSession()
            currentToken = token
            startingToken = token
            observeCommands(for: token)
            pip.onStandbyStopped = { [weak self] in
                self?.standbyStopped(token: token)
            }
            let stream = await engine.start(request)
            startingToken = nil
            guard currentToken == token, pip.isActive else {
                if currentToken == token { detachCurrentSession() }
                // PiP 丢失可能早于引擎接纳；此处再取消才保证有效且只执行一次。
                await engine.cancel(token: token)
                continue
            }
            consume(stream, request: request)
        }
    }

    func handleStopNotification(session: String) async {
        guard let token = currentToken, token.rawValue == session else { return }
        await engine.stop(token: token)
    }

    func handleCancelNotification(session: String) async {
        guard let token = currentToken, token.rawValue == session else { return }
        await engine.cancel(token: token)
    }

    private func observeCommands(for token: SessionToken) {
        if let name = DarwinBridge.sessionNotificationName(
            base: DarwinNotificationName.requestStopDictation, session: token.rawValue
        ) {
            stopObserver = DarwinNotificationObserver(name: name) { [weak self] in
                Task { @MainActor in
                    await self?.handleStopNotification(session: token.rawValue)
                }
            }
        }
        if let name = DarwinBridge.sessionNotificationName(
            base: DarwinNotificationName.requestCancelDictation, session: token.rawValue
        ) {
            cancelObserver = DarwinNotificationObserver(name: name) { [weak self] in
                Task { @MainActor in
                    await self?.handleCancelNotification(session: token.rawValue)
                }
            }
        }
    }

    private func consume(
        _ stream: AsyncStream<DictationSessionEventEnvelope>,
        request: DictationSessionRequest
    ) {
        let token = request.token
        eventConsumer = Task { @MainActor [weak self] in
            var lastText = ""
            var hasListened = false
            for await envelope in stream {
                guard let self, !Task.isCancelled, self.currentToken == token else { return }
                guard envelope.token == token else { continue }
                switch envelope.event {
                case .authorizing:
                    break
                case .preparing:
                    DarwinBridge.postSessionNotification(
                        base: DarwinNotificationName.dictationStarted, session: token.rawValue
                    )
                case .listening(let partial):
                    hasListened = true
                    lastText = request.processing.livePreviewEnabled ? partial : ""
                    self.pip.setRecording(text: lastText)
                case .processing:
                    self.pip.setProcessing(text: lastText)
                case .completed, .cancelled:
                    self.detachCurrentSession()
                    self.pip.returnToStandby()
                    return
                case .failed(let failure):
                    self.detachCurrentSession()
                    switch failure {
                    case .permissionRequiresForeground, .permissionDenied, .startTimeout:
                        self.pip.stopStandby()
                    case .recognitionUnavailable where !hasListened:
                        self.pip.stopStandby()
                    default:
                        self.pip.returnToStandby()
                    }
                    // 引擎已持久化会话终态；重试必须创建新 UUID，不能重排此请求。
                    return
                }
            }
            guard let self, self.currentToken == token else { return }
            self.detachCurrentSession()
            self.pip.stopStandby()
            await self.engine.cancel(token: token)
        }
    }

    private func standbyStopped(token: SessionToken) {
        guard currentToken == token else { return }
        let waitForAdmission = startingToken == token
        detachCurrentSession()
        if !waitForAdmission {
            Task { [engine] in await engine.cancel(token: token) }
        }
    }

    private func detachCurrentSession() {
        currentToken = nil
        eventConsumer?.cancel()
        eventConsumer = nil
        stopObserver = nil
        cancelObserver = nil
        pip.onStandbyStopped = nil
    }
}
