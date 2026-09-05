import AVFoundation
import Foundation

enum DictationAudioBufferCloseMode {
    case endAudio
    case cancel
}

final class DictationAudioBufferGate: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (any DictationSpeechSession)?

    init(sink: any DictationSpeechSession) {
        self.sink = sink
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        sink?.append(buffer)
    }

    func close(mode: DictationAudioBufferCloseMode) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = sink else { return }
        sink = nil
        switch mode {
        case .endAudio:
            current.endAudio()
        case .cancel:
            current.cancel()
        }
    }
}
