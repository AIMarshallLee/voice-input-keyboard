import Foundation

final class DictationSessionEnvironment: @unchecked Sendable {
    static let shared = DictationSessionEnvironment()

    let engine: DictationSessionEngine
    private let eventForwardingTask: Task<Void, Never>

    private init() {
        let eventSource = AppleDictationAudioSystemEventSource()
        let engine = DictationSessionEngine(
            permissions: AppleDictationPermissionResolver(),
            audioSession: AppleDictationAudioSessionController(),
            speechFactory: AppleSpeechSessionFactory(),
            audioFactory: AppleAudioCaptureFactory(),
            scheduler: DispatchDeadlineScheduler(),
            processor: TextProcessorDictationAdapter(processor: .shared),
            output: DarwinDictationSessionOutput(),
            deadlines: .production
        )
        self.engine = engine
        eventForwardingTask = Task { [eventSource, engine] in
            for await event in eventSource.events {
                await engine.handleAudioSystemEvent(event)
            }
        }
    }
}
