import AVFoundation
import Foundation

struct DictationSessionDeadlines: Equatable, Sendable {
    let start: TimeInterval
    let silence: TimeInterval
    let finalRecognition: TimeInterval
    let processing: TimeInterval
    let partialPublish: TimeInterval
    let foregroundClaim: TimeInterval

    static let production = DictationSessionDeadlines(
        start: 4.0,
        silence: 3.0,
        finalRecognition: 0.45,
        processing: 5.0,
        partialPublish: 0.20,
        foregroundClaim: 3.0
    )
}

enum DictationAudioSystemEvent: Equatable, Sendable {
    case interruptionBegan
    case inputRouteLost
    case mediaServicesReset
}

struct DictationRecognitionUpdate: Equatable, Sendable {
    let transcript: String
    let isFinal: Bool
}

protocol DictationPermissionResolving: Sendable {
    func authorize(
        policy: DictationAuthorizationPolicy
    ) async -> Result<Void, DictationFailure>
}

protocol DictationAudioSessionControlling: Sendable {
    func activate(whisper: Bool) throws
    func deactivate()
}

protocol DictationSpeechSession: AnyObject, Sendable {
    func append(_ buffer: AVAudioPCMBuffer)
    func endAudio()
    func cancel()
}

protocol DictationSpeechSessionCreating: Sendable {
    func makeSession(
        localeIdentifier: String,
        update: @escaping @Sendable (Result<DictationRecognitionUpdate, DictationFailure>) -> Void
    ) throws -> any DictationSpeechSession
}

protocol DictationAudioCaptureSession: AnyObject, Sendable {
    func start() throws
    func stop()
}

protocol DictationAudioCaptureCreating: Sendable {
    func makeSession(
        bufferHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) throws -> any DictationAudioCaptureSession
}

protocol DictationScheduledTask: Sendable {
    func cancel()
}

protocol DictationDeadlineScheduling: Sendable {
    func schedule(
        after interval: TimeInterval,
        action: @escaping @Sendable () -> Void
    ) -> any DictationScheduledTask
}

protocol DictationTextProcessing: Sendable {
    func process(
        transcript: String,
        snapshot: TextProcessingSnapshot
    ) async -> Result<EditPlan, DictationFailure>
}

protocol DictationSessionOutput: Sendable {
    func publishLive(
        _ envelope: DictationSessionEventEnvelope,
        request: DictationSessionRequest
    ) async

    func commit(
        _ terminal: DictationTerminal,
        token: SessionToken
    ) async -> DictationOutputCommitStatus
}

protocol DictationSessionRunning: Sendable {
    func start(
        _ request: DictationSessionRequest
    ) async -> AsyncStream<DictationSessionEventEnvelope>
    func stop(token: SessionToken) async
    func cancel(token: SessionToken) async
    func handleAudioSystemEvent(_ event: DictationAudioSystemEvent) async
}
