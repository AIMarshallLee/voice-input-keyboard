import AVFoundation
import Foundation
import Speech

enum DictationAuthorizationState: Equatable {
    case authorized
    case denied
    case notDetermined
}

enum DictationPermissionDecision: Equatable {
    case proceed
    case requestSpeech
    case requestMicrophone
    case fail(DictationFailure)

    static func next(
        speech: DictationAuthorizationState,
        microphone: DictationAuthorizationState,
        policy: DictationAuthorizationPolicy
    ) -> DictationPermissionDecision {
        if speech == .denied { return .fail(.permissionDenied(.speech)) }
        if microphone == .denied { return .fail(.permissionDenied(.microphone)) }
        if speech == .notDetermined {
            return policy == .requestIfNeeded
                ? .requestSpeech
                : .fail(.permissionRequiresForeground(.speech))
        }
        if microphone == .notDetermined {
            return policy == .requestIfNeeded
                ? .requestMicrophone
                : .fail(.permissionRequiresForeground(.microphone))
        }
        return .proceed
    }
}

final class AppleDictationPermissionResolver: @unchecked Sendable, DictationPermissionResolving {
    func authorize(
        policy: DictationAuthorizationPolicy
    ) async -> Result<Void, DictationFailure> {
        while true {
            switch DictationPermissionDecision.next(
                speech: speechAuthorizationState(),
                microphone: microphoneAuthorizationState(),
                policy: policy
            ) {
            case .proceed:
                return .success(())
            case .fail(let failure):
                return .failure(failure)
            case .requestSpeech:
                await requestSpeechAuthorization()
            case .requestMicrophone:
                await requestMicrophoneAuthorization()
            }
        }
    }

    private func speechAuthorizationState() -> DictationAuthorizationState {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return .authorized
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    private func microphoneAuthorizationState() -> DictationAuthorizationState {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            return .authorized
        case .undetermined:
            return .notDetermined
        case .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }

    private func requestSpeechAuthorization() async {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { _ in
                continuation.resume()
            }
        }
    }

    private func requestMicrophoneAuthorization() async {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { _ in
                continuation.resume()
            }
        }
    }
}

final class AppleDictationAudioSessionController: @unchecked Sendable, DictationAudioSessionControlling {
    func activate(whisper: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: whisper ? .voiceChat : .default,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers]
        )
        try session.setActive(true)
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }
}

final class AppleDictationAudioSystemEventSource: @unchecked Sendable {
    private let notificationCenter: NotificationCenter
    private let stream: AsyncStream<DictationAudioSystemEvent>
    private var streamContinuation: AsyncStream<DictationAudioSystemEvent>.Continuation?
    private var observers: [NSObjectProtocol] = []

    var events: AsyncStream<DictationAudioSystemEvent> { stream }

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        var continuation: AsyncStream<DictationAudioSystemEvent>.Continuation!
        stream = AsyncStream { continuation = $0 }
        streamContinuation = continuation
        continuation.onTermination = { [weak self] _ in
            self?.removeObservers(from: notificationCenter)
        }
        observers = [
            notificationCenter.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: typeValue) == .began else { return }
                self?.yield(.interruptionBegan)
            },
            notificationCenter.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      AVAudioSession.RouteChangeReason(rawValue: reasonValue) == .oldDeviceUnavailable else { return }
                self?.yield(.inputRouteLost)
            },
            notificationCenter.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.yield(.mediaServicesReset)
            }
        ]
    }

    deinit {
        removeObservers(from: notificationCenter)
    }

    private func yield(_ event: DictationAudioSystemEvent) {
        // A resume notification intentionally has no counterpart in this stream.
        streamContinuation?.yield(event)
    }

    private func removeObservers(from notificationCenter: NotificationCenter) {
        let tokens = observers
        observers.removeAll()
        tokens.forEach(notificationCenter.removeObserver)
    }
}

private enum AppleDictationAdapterError: Error {
    case recognitionUnavailable
    case audioCapture
}

final class AppleSpeechSessionFactory: @unchecked Sendable, DictationSpeechSessionCreating {
    func makeSession(
        localeIdentifier: String,
        update: @escaping @Sendable (Result<DictationRecognitionUpdate, DictationFailure>) -> Void
    ) throws -> any DictationSpeechSession {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable else {
            throw AppleDictationAdapterError.recognitionUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                update(.success(DictationRecognitionUpdate(
                    transcript: result.bestTranscription.formattedString,
                    isFinal: result.isFinal
                )))
            } else if error != nil {
                update(.failure(.recognition))
            }
        }
        return AppleSpeechSession(
            recognizer: recognizer,
            request: request,
            task: task
        )
    }
}

private final class AppleSpeechSession: @unchecked Sendable, DictationSpeechSession {
    private let recognizer: SFSpeechRecognizer
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let task: SFSpeechRecognitionTask

    init(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        task: SFSpeechRecognitionTask
    ) {
        self.recognizer = recognizer
        self.request = request
        self.task = task
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)
    }

    func endAudio() {
        request.endAudio()
    }

    func cancel() {
        task.cancel()
    }
}

final class AppleAudioCaptureFactory: @unchecked Sendable, DictationAudioCaptureCreating {
    func makeSession(
        bufferHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) throws -> any DictationAudioCaptureSession {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            throw AppleDictationAdapterError.audioCapture
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: recordingFormat
        ) { buffer, _ in
            bufferHandler(buffer)
        }
        return AppleAudioCaptureSession(engine: engine, inputNode: inputNode)
    }
}

private final class AppleAudioCaptureSession: @unchecked Sendable, DictationAudioCaptureSession {
    private let lock = NSLock()
    private let engine: AVAudioEngine
    private let inputNode: AVAudioInputNode
    private var didStop = false

    init(engine: AVAudioEngine, inputNode: AVAudioInputNode) {
        self.engine = engine
        self.inputNode = inputNode
    }

    func start() throws {
        engine.prepare()
        try engine.start()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !didStop else { return }
        didStop = true
        engine.stop()
        inputNode.removeTap(onBus: 0)
    }
}

final class DispatchDeadlineScheduler: @unchecked Sendable, DictationDeadlineScheduling {
    func schedule(
        after interval: TimeInterval,
        action: @escaping @Sendable () -> Void
    ) -> any DictationScheduledTask {
        let workItem = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: workItem)
        return DispatchScheduledTask(workItem: workItem)
    }
}

private final class DispatchScheduledTask: @unchecked Sendable, DictationScheduledTask {
    private let workItem: DispatchWorkItem

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem.cancel()
    }
}

final class TextProcessorDictationAdapter: @unchecked Sendable, DictationTextProcessing {
    private let processor: TextProcessor

    init(processor: TextProcessor) {
        self.processor = processor
    }

    func process(
        transcript: String,
        snapshot: TextProcessingSnapshot
    ) async -> Result<EditPlan, DictationFailure> {
        let result = await processor.process(
            transcript,
            selectedText: snapshot.selectedText,
            keyboardType: snapshot.keyboardType,
            language: snapshot.language,
            translateEnabled: snapshot.translateEnabled,
            translateTarget: snapshot.translateTarget,
            voiceEditEnabled: snapshot.voiceEditEnabled
        )
        return Self.plan(from: result, snapshot: snapshot)
    }

    static func plan(
        from result: TextProcessingResult,
        snapshot: TextProcessingSnapshot
    ) -> Result<EditPlan, DictationFailure> {
        switch result {
        case .failure:
            return .failure(.processing)
        case .deleteSelection:
            return .success(
                EditPlan(
                    intent: .delete,
                    operation: .deleteSelection,
                    text: "",
                    expectedContextFingerprint: snapshot.expectedContextFingerprint,
                    requiresConfirmation: true
                )
            )
        case .insert(let text):
            let hasSelectedEdit = snapshot.voiceEditEnabled
                && !(snapshot.selectedText?.isEmpty ?? true)
            let intent: EditIntent = snapshot.translateEnabled
                ? .translate(targetLanguage: snapshot.translateTarget)
                : (hasSelectedEdit ? .rewrite : .dictate)
            return .success(
                EditPlan(
                    intent: intent,
                    operation: hasSelectedEdit ? .replaceSelection : .insertAtCursor,
                    text: text,
                    expectedContextFingerprint: snapshot.expectedContextFingerprint,
                    requiresConfirmation: hasSelectedEdit
                )
            )
        }
    }
}

@MainActor
final class DarwinDictationSessionOutput: @unchecked Sendable, DictationSessionOutput {
    private var publishers: [SessionToken: DictationLiveStatePublisher] = [:]
    private var highestSequence: [SessionToken: UInt64] = [:]
    private var closedTokens: Set<SessionToken> = []
    private var startedTokens: Set<SessionToken> = []

    nonisolated init() {}

    func publishLive(
        _ envelope: DictationSessionEventEnvelope,
        request: DictationSessionRequest
    ) async {
        guard envelope.token == request.token,
              !closedTokens.contains(request.token),
              let publication = publication(for: envelope.event, request: request) else {
            return
        }
        guard envelope.sequence > (highestSequence[request.token] ?? 0) else { return }
        highestSequence[request.token] = envelope.sequence

        let publisher = publishers[request.token] ?? DictationLiveStatePublisher()
        publishers[request.token] = publisher
        let didWrite = publisher.publishImmediately(
            phase: publication.phase,
            partialTranscript: publication.partialTranscript,
            session: request.token.rawValue
        )
        if didWrite,
           publication.phase == .listening,
           startedTokens.insert(request.token).inserted {
            DarwinBridge.postSessionNotification(
                base: DarwinNotificationName.dictationStarted,
                session: request.token.rawValue
            )
        }
    }

    func commit(
        _ terminal: DictationTerminal,
        token: SessionToken
    ) async -> DictationOutputCommitStatus {
        closedTokens.insert(token)
        publishers[token]?.cancelPending(for: token.rawValue)
        publishers[token] = nil
        let status = DarwinBridge.commit(terminal, token: token)
        for name in Self.terminalNotificationNames(for: terminal, status: status) {
            DarwinBridge.postSessionNotification(base: name, session: token.rawValue)
        }
        return status
    }

    nonisolated static func terminalNotificationNames(
        for terminal: DictationTerminal,
        status: DictationOutputCommitStatus
    ) -> [String] {
        guard status == .written || status == .cancelled else { return [] }
        if case .failed = terminal, status == .written {
            return [
                DarwinNotificationName.dictationFailed,
                DarwinNotificationName.dictationStopped
            ]
        }
        return [DarwinNotificationName.dictationStopped]
    }

    private func publication(
        for event: DictationSessionEvent,
        request: DictationSessionRequest
    ) -> (phase: DictationLivePhase, partialTranscript: String)? {
        switch event {
        case .authorizing, .preparing:
            return (.starting, "")
        case .listening(let partial):
            let persistedPartial = request.processing.livePreviewEnabled || partial.isEmpty
                ? partial
                : ""
            return (.listening, persistedPartial)
        case .processing:
            return (.processing, "")
        case .completed, .failed, .cancelled:
            return nil
        }
    }
}
