import Foundation

actor DictationSessionEngine: DictationSessionRunning {
    private enum Phase: Equatable {
        case authorizing
        case preparing
        case listening
        case processing
    }

    private struct ActiveSession {
        let request: DictationSessionRequest
        let generation: UInt64
        var phase: Phase
        var nextSequence: UInt64
        var transcript: String
        var hasAcceptedFinalRecognition: Bool
        var pendingPartial: String?
        var continuation: AsyncStream<DictationSessionEventEnvelope>.Continuation
        var speech: (any DictationSpeechSession)?
        var audioCapture: (any DictationAudioCaptureSession)?
        var bufferGate: DictationAudioBufferGate?
        var startDeadline: (any DictationScheduledTask)?
        var silenceDeadline: (any DictationScheduledTask)?
        var finalDeadline: (any DictationScheduledTask)?
        var processingDeadline: (any DictationScheduledTask)?
        var partialDeadline: (any DictationScheduledTask)?
        var hasStartedTextProcessing: Bool
        var finishStarted: Bool
    }

    private struct FinishReservation {
        let token: SessionToken
        let terminal: DictationTerminal
        let sequence: UInt64
        let continuation: AsyncStream<DictationSessionEventEnvelope>.Continuation
    }

    private let permissions: any DictationPermissionResolving
    private let audioSession: any DictationAudioSessionControlling
    private let speechFactory: any DictationSpeechSessionCreating
    private let audioFactory: any DictationAudioCaptureCreating
    private let scheduler: any DictationDeadlineScheduling
    private let processor: any DictationTextProcessing
    private let output: any DictationSessionOutput
    private let deadlines: DictationSessionDeadlines
    private var nextGeneration: UInt64 = 0
    private var active: ActiveSession?

    init(
        permissions: any DictationPermissionResolving,
        audioSession: any DictationAudioSessionControlling,
        speechFactory: any DictationSpeechSessionCreating,
        audioFactory: any DictationAudioCaptureCreating,
        scheduler: any DictationDeadlineScheduling,
        processor: any DictationTextProcessing,
        output: any DictationSessionOutput,
        deadlines: DictationSessionDeadlines = .production
    ) {
        self.permissions = permissions
        self.audioSession = audioSession
        self.speechFactory = speechFactory
        self.audioFactory = audioFactory
        self.scheduler = scheduler
        self.processor = processor
        self.output = output
        self.deadlines = deadlines
    }

    func start(
        _ request: DictationSessionRequest
    ) async -> AsyncStream<DictationSessionEventEnvelope> {
        if let previous = active,
           let reservation = reserveFinish(
               .cancelled,
               token: previous.request.token,
               generation: previous.generation
           ) {
            Task { await self.completeFinish(reservation) }
        }

        nextGeneration &+= 1
        let generation = nextGeneration
        var continuation: AsyncStream<DictationSessionEventEnvelope>.Continuation!
        let stream = AsyncStream<DictationSessionEventEnvelope> { continuation = $0 }
        active = ActiveSession(
            request: request,
            generation: generation,
            phase: .authorizing,
            nextSequence: 1,
            transcript: "",
            hasAcceptedFinalRecognition: false,
            pendingPartial: nil,
            continuation: continuation,
            speech: nil,
            audioCapture: nil,
            bufferGate: nil,
            startDeadline: nil,
            silenceDeadline: nil,
            finalDeadline: nil,
            processingDeadline: nil,
            partialDeadline: nil,
            hasStartedTextProcessing: false,
            finishStarted: false
        )
        await emit(.authorizing, token: request.token, generation: generation)

        Task { [permissions] in
            guard let current = self.matching(token: request.token, generation: generation),
                  current.phase == .authorizing,
                  !current.finishStarted else { return }
            let result = await permissions.authorize(policy: request.authorizationPolicy)
            await self.authorizationResolved(
                result,
                token: request.token,
                generation: generation
            )
        }
        return stream
    }

    func stop(token: SessionToken) async {
        guard let current = active, current.request.token == token else { return }
        switch current.phase {
        case .authorizing, .preparing:
            await finish(.cancelled, token: token, generation: current.generation)
        case .listening:
            await beginProcessing(token: token, generation: current.generation)
        case .processing:
            return
        }
    }

    func cancel(token: SessionToken) async {
        guard let current = active, current.request.token == token else { return }
        await finish(.cancelled, token: token, generation: current.generation)
    }

    func handleAudioSystemEvent(_ event: DictationAudioSystemEvent) async {
        guard let current = active else { return }
        let failure: DictationFailure
        switch event {
        case .interruptionBegan:
            failure = .interrupted
        case .inputRouteLost:
            failure = .inputRouteLost
        case .mediaServicesReset:
            failure = .mediaServicesReset
        }
        await finish(
            .failed(failure),
            token: current.request.token,
            generation: current.generation
        )
    }

    func recognitionUpdated(
        _ result: Result<DictationRecognitionUpdate, DictationFailure>,
        token: SessionToken,
        generation: UInt64
    ) async {
        guard var current = matching(token: token, generation: generation),
              current.phase == .listening || current.phase == .processing,
              !current.hasAcceptedFinalRecognition else { return }
        switch result {
        case .failure(let failure):
            await finish(.failed(failure), token: token, generation: generation)
        case .success(let update):
            current.transcript = update.transcript
            current.hasAcceptedFinalRecognition = update.isFinal
            active = current
            if update.isFinal {
                if current.phase == .listening {
                    await beginProcessing(token: token, generation: generation)
                }
                await startTextProcessing(token: token, generation: generation)
            } else if current.phase == .listening {
                await emit(
                    .listening(partial: update.transcript),
                    token: token,
                    generation: generation
                )
            }
        }
    }

    private func authorizationResolved(
        _ result: Result<Void, DictationFailure>,
        token: SessionToken,
        generation: UInt64
    ) async {
        guard var current = matching(token: token, generation: generation),
              current.phase == .authorizing else { return }
        guard case .success = result else {
            if case .failure(let failure) = result {
                await finish(.failed(failure), token: token, generation: generation)
            }
            return
        }

        current.phase = .preparing
        active = current
        await emit(.preparing, token: token, generation: generation)
        guard let prepared = matching(token: token, generation: generation),
              prepared.phase == .preparing,
              !prepared.finishStarted else { return }

        do {
            try audioSession.activate(whisper: prepared.request.whisper)
        } catch {
            await finish(.failed(.audioSession), token: token, generation: generation)
            return
        }

        let speech: any DictationSpeechSession
        do {
            speech = try speechFactory.makeSession(
                localeIdentifier: prepared.request.processing.language
            ) { [weak self] result in
                Task {
                    await self?.recognitionUpdated(
                        result,
                        token: token,
                        generation: generation
                    )
                }
            }
        } catch {
            await finish(
                .failed(.recognitionUnavailable),
                token: token,
                generation: generation
            )
            return
        }

        let gate = DictationAudioBufferGate(sink: speech)
        let capture: any DictationAudioCaptureSession
        do {
            capture = try audioFactory.makeSession { buffer in gate.append(buffer) }
        } catch {
            gate.close(mode: .cancel)
            await finish(.failed(.audioCapture), token: token, generation: generation)
            return
        }

        do {
            try capture.start()
        } catch {
            capture.stop()
            gate.close(mode: .cancel)
            await finish(.failed(.audioCapture), token: token, generation: generation)
            return
        }

        guard var listening = matching(token: token, generation: generation),
              listening.phase == .preparing else {
            capture.stop()
            gate.close(mode: .cancel)
            audioSession.deactivate()
            return
        }
        listening.speech = speech
        listening.audioCapture = capture
        listening.bufferGate = gate
        listening.phase = .listening
        active = listening
        await emit(.listening(partial: ""), token: token, generation: generation)
    }

    private func beginProcessing(token: SessionToken, generation: UInt64) async {
        guard var current = matching(token: token, generation: generation),
              current.phase == .listening else { return }
        current.phase = .processing
        current.audioCapture?.stop()
        current.bufferGate?.close(mode: .endAudio)
        current.audioCapture = nil
        current.bufferGate = nil
        active = current
        audioSession.deactivate()
        await emit(.processing, token: token, generation: generation)
    }

    private func startTextProcessing(token: SessionToken, generation: UInt64) async {
        guard var current = matching(token: token, generation: generation),
              current.phase == .processing,
              !current.hasStartedTextProcessing else { return }
        let transcript = current.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            await finish(.failed(.noSpeech), token: token, generation: generation)
            return
        }
        current.hasStartedTextProcessing = true
        let snapshot = current.request.processing
        active = current
        Task { [processor] in
            let result = await processor.process(transcript: transcript, snapshot: snapshot)
            await self.processingFinished(result, token: token, generation: generation)
        }
    }

    private func processingFinished(
        _ result: Result<EditPlan, DictationFailure>,
        token: SessionToken,
        generation: UInt64
    ) async {
        guard matching(token: token, generation: generation) != nil else { return }
        switch result {
        case .success(let plan):
            await finish(.completed(plan), token: token, generation: generation)
        case .failure(let failure):
            await finish(.failed(failure), token: token, generation: generation)
        }
    }

    private func reserveFinish(
        _ terminal: DictationTerminal,
        token: SessionToken,
        generation: UInt64
    ) -> FinishReservation? {
        guard var current = matching(token: token, generation: generation),
              !current.finishStarted else { return nil }
        current.finishStarted = true
        cancelDeadlines(in: &current)
        current.audioCapture?.stop()
        if let gate = current.bufferGate {
            gate.close(mode: terminal.bufferCloseMode)
        } else {
            current.speech?.cancel()
        }
        audioSession.deactivate()
        active = nil
        return FinishReservation(
            token: token,
            terminal: terminal,
            sequence: current.nextSequence,
            continuation: current.continuation
        )
    }

    private func finish(
        _ terminal: DictationTerminal,
        token: SessionToken,
        generation: UInt64
    ) async {
        guard let reservation = reserveFinish(
            terminal,
            token: token,
            generation: generation
        ) else { return }
        await completeFinish(reservation)
    }

    private func completeFinish(_ reservation: FinishReservation) async {
        let commitStatus = await output.commit(
            reservation.terminal,
            token: reservation.token
        )
        let delivered: DictationSessionEvent
        switch commitStatus {
        case .written:
            delivered = reservation.terminal.event
        case .cancelled:
            delivered = .cancelled
        case .alreadyTerminal:
            delivered = reservation.terminal.event
        case .ioFailure:
            delivered = .failed(.outputPersistence)
        }
        reservation.continuation.yield(
            DictationSessionEventEnvelope(
                token: reservation.token,
                sequence: reservation.sequence,
                event: delivered
            )
        )
        reservation.continuation.finish()
    }

    private func matching(
        token: SessionToken,
        generation: UInt64
    ) -> ActiveSession? {
        guard let current = active,
              current.request.token == token,
              current.generation == generation else { return nil }
        return current
    }

    private func emit(
        _ event: DictationSessionEvent,
        token: SessionToken,
        generation: UInt64
    ) async {
        guard var current = matching(token: token, generation: generation) else { return }
        let envelope = DictationSessionEventEnvelope(
            token: token,
            sequence: current.nextSequence,
            event: event
        )
        current.nextSequence &+= 1
        let continuation = current.continuation
        active = current
        continuation.yield(envelope)

        switch event {
        case .authorizing, .preparing, .listening, .processing:
            await output.publishLive(envelope, request: current.request)
            guard matching(token: token, generation: generation) != nil else { return }
        case .completed, .failed, .cancelled:
            return
        }
    }

    private func cancelDeadlines(in session: inout ActiveSession) {
        session.startDeadline?.cancel()
        session.silenceDeadline?.cancel()
        session.finalDeadline?.cancel()
        session.processingDeadline?.cancel()
        session.partialDeadline?.cancel()
        session.startDeadline = nil
        session.silenceDeadline = nil
        session.finalDeadline = nil
        session.processingDeadline = nil
        session.partialDeadline = nil
    }
}

private extension DictationTerminal {
    var event: DictationSessionEvent {
        switch self {
        case .completed(let plan):
            return .completed(plan)
        case .failed(let failure):
            return .failed(failure)
        case .cancelled:
            return .cancelled
        }
    }

    var bufferCloseMode: DictationAudioBufferCloseMode {
        switch self {
        case .completed:
            return .endAudio
        case .failed, .cancelled:
            return .cancel
        }
    }
}
