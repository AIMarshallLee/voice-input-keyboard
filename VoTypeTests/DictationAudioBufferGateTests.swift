import AVFoundation
import XCTest
@testable import VoiceInputApp

final class DictationAudioBufferGateTests: XCTestCase {
    func testCloseWaitsForInFlightAppendAndRejectsLaterBuffers() throws {
        let sink = BlockingSpeechSession()
        defer { sink.releaseAppend.signal() }

        let gate = DictationAudioBufferGate(sink: sink)
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        let appendStarted = expectation(description: "append started")
        sink.onAppendStarted = { appendStarted.fulfill() }

        DispatchQueue.global().async { gate.append(buffer) }
        wait(for: [appendStarted], timeout: 1)

        let closeStarted = DispatchSemaphore(value: 0)
        let closeReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            closeStarted.signal()
            gate.close(mode: .cancel)
            closeReturned.signal()
        }

        XCTAssertEqual(closeStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(closeReturned.wait(timeout: .now() + 0.05), .timedOut)

        sink.releaseAppend.signal()
        let closeCompleted = closeReturned.wait(timeout: .now() + 1)
        XCTAssertEqual(closeCompleted, .success)
        guard closeCompleted == .success else { return }

        let appendCompleted = sink.appendReturned.wait(timeout: .now() + 1)
        XCTAssertEqual(appendCompleted, .success)
        guard appendCompleted == .success else { return }
        XCTAssertFalse(sink.appendTimedOut)

        gate.append(buffer)

        XCTAssertEqual(sink.appendCount, 1)
        XCTAssertEqual(sink.cancelCount, 1)
        XCTAssertEqual(sink.endAudioCount, 0)
    }

    func testEndAudioRunsOnce() throws {
        let sink = BlockingSpeechSession(blocksAppend: false)
        let gate = DictationAudioBufferGate(sink: sink)

        gate.close(mode: .endAudio)
        gate.close(mode: .endAudio)

        XCTAssertEqual(sink.endAudioCount, 1)
        XCTAssertEqual(sink.cancelCount, 0)
    }
}

private final class BlockingSpeechSession: @unchecked Sendable, DictationSpeechSession {
    let releaseAppend = DispatchSemaphore(value: 0)
    let appendReturned = DispatchSemaphore(value: 0)
    var onAppendStarted: (() -> Void)?
    private let blocksAppend: Bool
    private let lock = NSLock()
    private var storedAppendCount = 0
    private var storedEndAudioCount = 0
    private var storedCancelCount = 0
    private var storedAppendTimedOut = false

    init(blocksAppend: Bool = true) {
        self.blocksAppend = blocksAppend
    }

    var appendCount: Int { locked { storedAppendCount } }
    var endAudioCount: Int { locked { storedEndAudioCount } }
    var cancelCount: Int { locked { storedCancelCount } }
    var appendTimedOut: Bool { locked { storedAppendTimedOut } }

    func append(_ buffer: AVAudioPCMBuffer) {
        locked { storedAppendCount += 1 }
        onAppendStarted?()
        if blocksAppend {
            let releaseResult = releaseAppend.wait(timeout: .now() + 2)
            if releaseResult == .timedOut {
                locked { storedAppendTimedOut = true }
            }
        }
        appendReturned.signal()
    }

    func endAudio() { locked { storedEndAudioCount += 1 } }
    func cancel() { locked { storedCancelCount += 1 } }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
