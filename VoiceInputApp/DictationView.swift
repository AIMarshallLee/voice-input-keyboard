import SwiftUI
import UIKit

/// 前台只持有请求归属和展示状态；权限、音频、识别及终态由共享引擎拥有。
@MainActor
final class DictationViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var liveText = ""
    @Published var statusMessage = "准备中..."
    @Published var hasResult = false
    @Published var permissionError: String?
    @Published var canExit = false
    @Published private(set) var shouldDismiss = false

    private(set) var languageID = "zh-CN"
    private(set) var whisperMode = false
    private(set) var translateEnabled = false
    private(set) var translateTarget = "en-US"
    private(set) var selectedText: String?
    private(set) var sessionId = ""
    private(set) var keyboardType = 0
    private(set) var hasValidSettings = false

    private let engine: any DictationSessionRunning
    private let scheduler: any DictationDeadlineScheduling
    private let deadlines: DictationSessionDeadlines
    private var foregroundClaimTask: (any DictationScheduledTask)?
    private var stopObserver: DarwinNotificationObserver?
    private var cancelObserver: DarwinNotificationObserver?
    private var attempt: PresentationAttempt?
    private var startInFlight = false

    // UI-only identity also distinguishes cleanup/reload of the same IPC UUID.
    private final class PresentationAttempt {
        let settings: DictationSettings
        let request: DictationSessionRequest
        var claimed = false
        var expired = false
        var returned = false
        var stopRequested = false
        var stopSent = false
        var cancelSent = false

        init(settings: DictationSettings, request: DictationSessionRequest) {
            self.settings = settings
            self.request = request
        }
    }

    var engineIdentity: ObjectIdentifier { ObjectIdentifier(engine as AnyObject) }

    init(
        engine: any DictationSessionRunning = DictationSessionEnvironment.shared.engine,
        scheduler: any DictationDeadlineScheduling = DispatchDeadlineScheduler(),
        deadlines: DictationSessionDeadlines = .production
    ) {
        self.engine = engine
        self.scheduler = scheduler
        self.deadlines = deadlines
    }

    func loadSettings(from url: URL?, expectedSession explicitSession: String? = nil) {
        // Reappearing while pending or running must not renew the claim or start twice.
        guard attempt == nil else { return }
        let expectedSession: String?
        if let explicitSession {
            guard DictationConstants.isValidSession(explicitSession) else {
                rejectUnavailableSettings()
                return
            }
            expectedSession = explicitSession
        } else if let url {
            guard url.scheme == DictationConstants.urlScheme,
                  url.host == DictationConstants.dictationPath,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let value = components.queryItems?.first(where: {
                      $0.name == DictationConstants.paramSession
                  })?.value,
                  DictationConstants.isValidSession(value) else {
                rejectUnavailableSettings()
                return
            }
            expectedSession = value
        } else {
            expectedSession = nil
        }
        let settings: DictationSettings?
        if let expectedSession {
            settings = DarwinBridge.peekDictationSettings(expectedSession: expectedSession)
        } else {
            settings = DarwinBridge.peekPendingDictationSettings()
        }
        guard let settings,
              let token = SessionToken(rawValue: settings.session),
              !DarwinBridge.isSessionCancelled(session: settings.session) else {
            rejectUnavailableSettings()
            return
        }

        let request = DictationSessionRequest(
            token: token, entryPoint: .foreground, authorizationPolicy: .requestIfNeeded,
            whisper: settings.whisper,
            processing: TextProcessingSnapshot(
                selectedText: settings.selectedText, keyboardType: settings.keyboardType,
                language: settings.language, translateEnabled: settings.translateEnabled,
                translateTarget: settings.translateTarget,
                voiceEditEnabled: TextProcessor.shared.voiceEditEnabled,
                livePreviewEnabled: TextProcessor.shared.livePreviewEnabled,
                expectedContextFingerprint: settings.expectedContextFingerprint
            )
        )
        let loaded = PresentationAttempt(settings: settings, request: request)
        attempt = loaded
        sessionId = settings.session
        languageID = settings.language
        whisperMode = settings.whisper
        translateEnabled = settings.translateEnabled
        translateTarget = settings.translateTarget
        selectedText = settings.selectedText
        keyboardType = settings.keyboardType
        hasValidSettings = true
        isRecording = false
        liveText = ""
        statusMessage = "准备中..."
        hasResult = false
        permissionError = nil
        canExit = false
        shouldDismiss = false
        observeCommands(for: loaded)
        foregroundClaimTask = scheduler.schedule(after: deadlines.foregroundClaim) {
            Task { @MainActor [weak self, weak loaded] in
                guard let self, let loaded, self.attempt === loaded, !loaded.claimed else { return }
                loaded.expired = true
                self.hasValidSettings = false
                self.showFailure("未能启动该语音请求，请返回键盘重试")
            }
        }
    }

    func startRecording() async {
        guard let current = attempt, hasValidSettings, !current.expired,
              !current.claimed, !startInFlight else { return }
        guard let claimed = DarwinBridge.readAndConsumeDictationSettings(
            expectedSession: current.request.token.rawValue
        ), claimed == current.settings else {
            detach()
            showFailure("该语音请求已由另一入口处理，请返回键盘重试")
            return
        }
        // Exact synchronous claim is the ownership boundary, before the first await.
        current.claimed = true
        foregroundClaimTask?.cancel()
        foregroundClaimTask = nil
        startInFlight = true
        let stream = await engine.start(current.request)
        startInFlight = false
        current.returned = true
        guard attempt === current, !Task.isCancelled else {
            if attempt === current { detach() }
            await cancelEngineOnce(current)
            return
        }
        if current.stopRequested { await forwardStop(current) }
        var handshake = false
        var sequence: UInt64?
        for await envelope in stream {
            guard attempt === current, !Task.isCancelled else {
                if attempt === current {
                    detach()
                    await cancelEngineOnce(current)
                }
                return
            }
            guard envelope.token == current.request.token else { continue }
            if let sequence, envelope.sequence <= sequence { continue }
            sequence = envelope.sequence
            if !handshake {
                guard envelope.event == .authorizing else {
                    await failStream(current)
                    return
                }
                handshake = true
            }
            switch envelope.event {
            case .authorizing, .preparing:
                isRecording = false
                statusMessage = "正在启动..."
            case .listening(let partial):
                isRecording = true
                liveText = partial
                statusMessage = "正在聆听..."
            case .processing:
                isRecording = false
                statusMessage = "正在处理文字..."
            case .completed:
                detach()
                hasResult = true
                canExit = true
                statusMessage = "识别完成 ✓"
                return
            case .failed(let failure):
                detach()
                showFailure(failure.userMessage)
                return
            case .cancelled:
                detach()
                statusMessage = "已取消"
                canExit = true
                shouldDismiss = true
                return
            }
        }
        guard attempt === current else { return }
        if Task.isCancelled {
            detach()
            await cancelEngineOnce(current)
        } else {
            await failStream(current)
        }
    }

    func stopRecording() async {
        guard let current = attempt else { return }
        current.stopRequested = true
        if current.claimed && current.returned { await forwardStop(current) }
    }

    private func forwardStop(_ current: PresentationAttempt) async {
        guard attempt === current, !current.stopSent else { return }
        current.stopSent = true
        await engine.stop(token: current.request.token)
    }

    func cancelRecording() async {
        guard let current = attempt else { return }
        detach()
        statusMessage = "已取消"
        canExit = true
        shouldDismiss = true
        if current.claimed && current.returned { await cancelEngineOnce(current) }
        // If start is suspended, its return path owns the effective cancellation.
    }

    func cleanup() {
        let current = attempt
        detach()
        if let current, current.claimed, current.returned, !current.cancelSent {
            current.cancelSent = true
            Task { [engine] in await engine.cancel(token: current.request.token) }
        }
    }

    private func detach() {
        foregroundClaimTask?.cancel()
        foregroundClaimTask = nil
        attempt = nil
        stopObserver = nil
        cancelObserver = nil
        hasValidSettings = false
        isRecording = false
    }

    private func cancelEngineOnce(_ current: PresentationAttempt) async {
        guard !current.cancelSent else { return }
        current.cancelSent = true
        await engine.cancel(token: current.request.token)
    }

    private func failStream(_ current: PresentationAttempt) async {
        guard attempt === current else { return }
        detach()
        showFailure(DictationFailure.recognition.userMessage)
        await cancelEngineOnce(current)
    }

    private func showFailure(_ message: String) {
        permissionError = message
        statusMessage = message
        isRecording = false
        canExit = true
    }

    private func rejectUnavailableSettings() {
        // A repeated appearance after a terminal must keep its result presentation.
        guard !hasResult, !canExit else { return }
        showFailure("听写请求无效，请返回键盘重试")
    }

    private func observeCommands(for current: PresentationAttempt) {
        let token = current.request.token
        if let name = DarwinBridge.sessionNotificationName(
            base: DarwinNotificationName.requestStopDictation, session: token.rawValue
        ) {
            stopObserver = DarwinNotificationObserver(name: name) { [weak self, weak current] in
                Task { @MainActor in
                    guard let self, let current, self.attempt === current else { return }
                    if DarwinBridge.isSessionCancelled(session: token.rawValue) {
                        await self.cancelRecording()
                    } else {
                        await self.stopRecording()
                    }
                }
            }
        }
        if let name = DarwinBridge.sessionNotificationName(
            base: DarwinNotificationName.requestCancelDictation, session: token.rawValue
        ) {
            cancelObserver = DarwinNotificationObserver(name: name) { [weak self, weak current] in
                Task { @MainActor in
                    guard let self, let current, self.attempt === current else { return }
                    await self.cancelRecording()
                }
            }
        }
    }
}

// MARK: - View

/// 容器 App 的语音听写页面
/// 用户打开 VoType 后消费键盘留在 App Group 中的会话并开始录音。
@MainActor
struct DictationView: View {
    @StateObject private var viewModel: DictationViewModel
    @Environment(\.dismiss) var dismiss
    let expectedSession: String
    var url: URL?

    init(
        expectedSession: String,
        url: URL? = nil,
        engine: any DictationSessionRunning = DictationSessionEnvironment.shared.engine,
        scheduler: any DictationDeadlineScheduling = DispatchDeadlineScheduler(),
        deadlines: DictationSessionDeadlines = .production
    ) {
        self.expectedSession = expectedSession
        self.url = url
        _viewModel = StateObject(wrappedValue: DictationViewModel(
            engine: engine, scheduler: scheduler, deadlines: deadlines
        ))
    }

    var body: some View {
        ZStack {
            // 背景色
            Color.black.opacity(0.95).ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // 状态图标
                VStack(spacing: 12) {
                    Image(systemName: viewModel.hasResult ? "checkmark.circle.fill" : (viewModel.isRecording ? "waveform.circle.fill" : "mic.circle.fill"))
                        .font(.system(size: 72))
                        .foregroundColor(viewModel.hasResult ? .green : (viewModel.isRecording ? .red : .blue))

                    Text(viewModel.hasResult ? "识别完成" : (viewModel.isRecording ? "正在聆听..." : "语音输入"))
                        .font(.title.bold())
                        .foregroundColor(.white)

                    Text(viewModel.statusMessage)
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                .padding(.top, 20)

                // 实时识别文本
                ScrollView {
                    if viewModel.liveText.isEmpty {
                        Text(viewModel.isRecording ? "等待说话..." : "识别结果将显示在这里")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text(viewModel.liveText)
                            .font(.title3)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                }
                .frame(maxHeight: .infinity)

                // 错误提示
                if let error = viewModel.permissionError {
                    VStack(spacing: 10) {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                        Button("前往系统设置") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                }

                Spacer()

                // 底部操作按钮
                VStack(spacing: 16) {
                    if viewModel.hasResult {
                        Text("文字已就绪，返回键盘即可")
                            .font(.subheadline)
                            .foregroundColor(.blue)
                            .multilineTextAlignment(.center)

                        Button("完成") {
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else if viewModel.isRecording {
                        Button(action: { Task { await viewModel.stopRecording() } }) {
                            Label("说完,点击停止", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.large)
                        .padding(.horizontal)
                    } else if viewModel.canExit {
                        Button("返回") { dismiss() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    } else if viewModel.permissionError == nil {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("正在启动...")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            viewModel.loadSettings(
                from: url,
                expectedSession: expectedSession
            )
            Task { await viewModel.startRecording() }
        }
        .task(id: viewModel.hasResult) {
            guard viewModel.hasResult else { return }
            let completedSession = viewModel.sessionId
            do {
                try await Task.sleep(nanoseconds: 2_500_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, viewModel.hasResult,
                  viewModel.sessionId == completedSession else { return }
            dismiss()
        }
        .onChange(of: viewModel.shouldDismiss) { shouldDismiss in
            if shouldDismiss { dismiss() }
        }
        .onDisappear {
            viewModel.cleanup()
        }
    }
}
