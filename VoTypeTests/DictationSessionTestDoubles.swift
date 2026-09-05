import AVFoundation
import Foundation
import XCTest
@testable import VoiceInputApp

enum DictationTestWaitFailure: Error, CustomStringConvertible {
    case timedOut(String)
    case conditionChanged(String)
    case missingValue(String)

    var description: String {
        switch self {
        case .timedOut(let description):
            return "Timed out waiting for \(description)"
        case .conditionChanged(let description):
            return "Condition changed while waiting for \(description)"
        case .missingValue(let description):
            return "Missing \(description) after its readiness condition was met"
        }
    }
}

func waitUntil(
    _ description: String,
    timeout: TimeInterval = 1,
    pollNanoseconds: UInt64 = 5_000_000,
    condition: () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(nanoseconds: pollNanoseconds)
    }
    guard await condition() else {
        throw DictationTestWaitFailure.timedOut(description)
    }
}

func requireStableCondition(
    _ description: String,
    duration: TimeInterval = 0.2,
    pollNanoseconds: UInt64 = 5_000_000,
    condition: () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(duration)
    repeat {
        guard await condition() else {
            throw DictationTestWaitFailure.conditionChanged(description)
        }
        try await Task.sleep(nanoseconds: pollNanoseconds)
    } while Date() < deadline
}

func runBoundedOperation(
    _ description: String,
    timeout: TimeInterval = 1,
    operation: @escaping @Sendable () async -> Void
) async throws {
    let completed = LockedTestBox(false)
    let task = Task {
        await operation()
        completed.set(true)
    }
    defer { task.cancel() }
    try await waitUntil(description, timeout: timeout) {
        completed.value
    }
}

final class LockedTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set(_ value: Value) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

final class TestOperationJournal: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEntries: [String] = []

    var entries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedEntries
    }

    func record(_ entry: String) {
        lock.lock()
        storedEntries.append(entry)
        lock.unlock()
    }
}

final class EventStreamRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [DictationSessionEventEnvelope] = []
    private var storedFinished = false
    private var collectionTask: Task<Void, Never>?

    init(stream: AsyncStream<DictationSessionEventEnvelope>) {
        collectionTask = Task { [weak self] in
            for await event in stream {
                self?.record(event)
            }
            self?.markFinished()
        }
    }

    deinit {
        collectionTask?.cancel()
    }

    var events: [DictationSessionEventEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedFinished
    }

    func cancel() {
        collectionTask?.cancel()
        collectionTask = nil
    }

    private func record(_ event: DictationSessionEventEnvelope) {
        lock.lock()
        storedEvents.append(event)
        lock.unlock()
    }

    private func markFinished() {
        lock.lock()
        storedFinished = true
        lock.unlock()
    }
}

final class PendingEngineStart: @unchecked Sendable {
    private let streamBox: LockedTestBox<AsyncStream<DictationSessionEventEnvelope>?>
    private let task: Task<Void, Never>

    init(engine: DictationSessionEngine, request: DictationSessionRequest) {
        let streamBox = LockedTestBox<AsyncStream<DictationSessionEventEnvelope>?>(nil)
        self.streamBox = streamBox
        task = Task {
            let stream = await engine.start(request)
            streamBox.set(stream)
        }
    }

    func waitForRecorder(timeout: TimeInterval = 1) async throws -> EventStreamRecorder {
        try await waitUntil("engine start to return a stream", timeout: timeout) {
            self.streamBox.value != nil
        }
        guard let stream = streamBox.value else {
            throw DictationTestWaitFailure.missingValue("engine stream")
        }
        return EventStreamRecorder(stream: stream)
    }

    func cancel() {
        task.cancel()
    }
}

final class StubAudioSessionController: @unchecked Sendable, DictationAudioSessionControlling {
    private let lock = NSLock()
    private let journal: TestOperationJournal
    private var storedActivationError: Error?
    private var storedActivatedWhisperValues: [Bool] = []
    private var storedDeactivateCount = 0

    init(journal: TestOperationJournal) {
        self.journal = journal
    }

    var activatedWhisperValues: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storedActivatedWhisperValues
    }

    var deactivateCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedDeactivateCount
    }

    func setActivationError(_ error: Error?) {
        lock.lock()
        storedActivationError = error
        lock.unlock()
    }

    func activate(whisper: Bool) throws {
        let error: Error? = locked {
            storedActivatedWhisperValues.append(whisper)
            return storedActivationError
        }
        if let error { throw error }
        journal.record("audio.activate")
    }

    func deactivate() {
        locked { storedDeactivateCount += 1 }
        journal.record("audio.deactivate")
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class ManualSpeechFactory: @unchecked Sendable, DictationSpeechSessionCreating {
    private let lock = NSLock()
    private let journal: TestOperationJournal
    private var handlers: [@Sendable (Result<DictationRecognitionUpdate, DictationFailure>) -> Void] = []
    private var sessions: [RecordingSpeechSession] = []

    init(journal: TestOperationJournal) {
        self.journal = journal
    }

    var sessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.count
    }

    func session(at index: Int) -> RecordingSpeechSession {
        lock.lock()
        defer { lock.unlock() }
        return sessions[index]
    }

    func makeSession(
        localeIdentifier: String,
        update: @escaping @Sendable (Result<DictationRecognitionUpdate, DictationFailure>) -> Void
    ) throws -> any DictationSpeechSession {
        let session: RecordingSpeechSession = locked {
            let index = sessions.count
            let session = RecordingSpeechSession(index: index, journal: journal)
            handlers.append(update)
            sessions.append(session)
            return session
        }
        journal.record("speech.\(session.index).create")
        return session
    }

    func send(
        _ result: Result<DictationRecognitionUpdate, DictationFailure>,
        index: Int
    ) {
        let handler = locked { handlers[index] }
        handler(result)
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class RecordingSpeechSession: @unchecked Sendable, DictationSpeechSession {
    let index: Int
    private let lock = NSLock()
    private let journal: TestOperationJournal
    private var storedAppendCount = 0
    private var storedEndAudioCount = 0
    private var storedCancelCount = 0

    init(index: Int, journal: TestOperationJournal) {
        self.index = index
        self.journal = journal
    }

    var appendCount: Int { locked { storedAppendCount } }
    var endAudioCount: Int { locked { storedEndAudioCount } }
    var cancelCount: Int { locked { storedCancelCount } }

    func append(_ buffer: AVAudioPCMBuffer) {
        locked { storedAppendCount += 1 }
        journal.record("speech.\(index).append")
    }

    func endAudio() {
        locked { storedEndAudioCount += 1 }
        journal.record("speech.\(index).endAudio")
    }

    func cancel() {
        locked { storedCancelCount += 1 }
        journal.record("speech.\(index).cancel")
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class ManualAudioCaptureFactory: @unchecked Sendable, DictationAudioCaptureCreating {
    private let lock = NSLock()
    private let journal: TestOperationJournal
    private var sessions: [RecordingAudioCaptureSession] = []
    private var nextStartError: Error?

    init(journal: TestOperationJournal) {
        self.journal = journal
    }

    var sessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.count
    }

    func session(at index: Int) -> RecordingAudioCaptureSession {
        lock.lock()
        defer { lock.unlock() }
        return sessions[index]
    }

    func setNextStartError(_ error: Error?) {
        lock.lock()
        nextStartError = error
        lock.unlock()
    }

    func makeSession(
        bufferHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) throws -> any DictationAudioCaptureSession {
        let session: RecordingAudioCaptureSession = locked {
            let session = RecordingAudioCaptureSession(
                index: sessions.count,
                journal: journal,
                startError: nextStartError,
                bufferHandler: bufferHandler
            )
            nextStartError = nil
            sessions.append(session)
            return session
        }
        journal.record("capture.\(session.index).create")
        return session
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class RecordingAudioCaptureSession: @unchecked Sendable, DictationAudioCaptureSession {
    let index: Int
    private let lock = NSLock()
    private let journal: TestOperationJournal
    private let startError: Error?
    private let bufferHandler: @Sendable (AVAudioPCMBuffer) -> Void
    private var storedStartCount = 0
    private var storedStopCount = 0

    init(
        index: Int,
        journal: TestOperationJournal,
        startError: Error?,
        bufferHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) {
        self.index = index
        self.journal = journal
        self.startError = startError
        self.bufferHandler = bufferHandler
    }

    var startCount: Int { locked { storedStartCount } }
    var stopCount: Int { locked { storedStopCount } }

    func start() throws {
        locked { storedStartCount += 1 }
        journal.record("capture.\(index).start")
        if let startError { throw startError }
    }

    func stop() {
        locked { storedStopCount += 1 }
        journal.record("capture.\(index).stop")
    }

    func deliver(_ buffer: AVAudioPCMBuffer) {
        bufferHandler(buffer)
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class RecordingScheduledTask: @unchecked Sendable, DictationScheduledTask {
    private let lock = NSLock()
    private var storedCancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedCancelled
    }

    func cancel() {
        lock.lock()
        storedCancelled = true
        lock.unlock()
    }
}

final class ManualDeadlineScheduler: @unchecked Sendable, DictationDeadlineScheduling {
    struct Pending {
        let interval: TimeInterval
        let action: @Sendable () -> Void
        let task: RecordingScheduledTask
    }

    private let lock = NSLock()
    private var storedPending: [Pending] = []

    var pending: [Pending] {
        lock.lock()
        defer { lock.unlock() }
        return storedPending
    }

    func schedule(
        after interval: TimeInterval,
        action: @escaping @Sendable () -> Void
    ) -> any DictationScheduledTask {
        let task = RecordingScheduledTask()
        lock.lock()
        storedPending.append(Pending(interval: interval, action: action, task: task))
        lock.unlock()
        return task
    }

    func fire(interval: TimeInterval) {
        let matches: [Pending] = locked {
            let matches = storedPending.filter {
                $0.interval == interval && !$0.task.isCancelled
            }
            storedPending.removeAll { $0.interval == interval }
            return matches
        }
        matches.forEach { $0.action() }
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class PermissionResultGate: @unchecked Sendable {
    private let lock = NSLock()
    private var queuedResult: Result<Void, DictationFailure>?
    private var waiters: [CheckedContinuation<Result<Void, DictationFailure>, Never>] = []

    func wait() async -> Result<Void, DictationFailure> {
        await withCheckedContinuation { continuation in
            var immediate: Result<Void, DictationFailure>?
            lock.lock()
            if let queuedResult {
                immediate = queuedResult
                self.queuedResult = nil
            } else {
                waiters.append(continuation)
            }
            lock.unlock()
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
    }

    func resume(with result: Result<Void, DictationFailure>) {
        let continuations: [CheckedContinuation<Result<Void, DictationFailure>, Never>]
        lock.lock()
        if waiters.isEmpty {
            queuedResult = result
            continuations = []
        } else {
            continuations = waiters
            waiters.removeAll()
        }
        lock.unlock()
        continuations.forEach { $0.resume(returning: result) }
    }
}

final class ManualPermissionResolver: @unchecked Sendable, DictationPermissionResolving {
    private let lock = NSLock()
    private let gate: PermissionResultGate?
    private var storedPolicies: [DictationAuthorizationPolicy] = []
    private var storedResult: Result<Void, DictationFailure> = .success(())

    init(suspends: Bool = false) {
        gate = suspends ? PermissionResultGate() : nil
    }

    var policies: [DictationAuthorizationPolicy] {
        lock.lock()
        defer { lock.unlock() }
        return storedPolicies
    }

    func setResult(_ result: Result<Void, DictationFailure>) {
        lock.lock()
        storedResult = result
        lock.unlock()
    }

    func authorize(
        policy: DictationAuthorizationPolicy
    ) async -> Result<Void, DictationFailure> {
        let result: Result<Void, DictationFailure> = locked {
            storedPolicies.append(policy)
            return storedResult
        }
        guard let gate else { return result }
        return await gate.wait()
    }

    func resume(with result: Result<Void, DictationFailure>) {
        gate?.resume(with: result)
    }

    func releaseForCleanup() {
        gate?.resume(with: .failure(.interrupted))
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

actor RecordingTextProcessor: DictationTextProcessing {
    private var result: Result<EditPlan, DictationFailure>
    private(set) var calls: [(String, TextProcessingSnapshot)] = []

    init(result: Result<EditPlan, DictationFailure>) {
        self.result = result
    }

    func setResult(_ result: Result<EditPlan, DictationFailure>) {
        self.result = result
    }

    func process(
        transcript: String,
        snapshot: TextProcessingSnapshot
    ) async -> Result<EditPlan, DictationFailure> {
        calls.append((transcript, snapshot))
        return result
    }
}

final class OutputGateBank: @unchecked Sendable {
    enum Kind: Hashable {
        case publishLive
        case commit
    }

    private struct Key: Hashable {
        let kind: Kind
        let token: SessionToken
    }

    private let lock = NSLock()
    private var enabled: Set<Key> = []
    private var waiters: [Key: [CheckedContinuation<Void, Never>]] = [:]

    func enable(_ kind: Kind, token: SessionToken) {
        lock.lock()
        enabled.insert(Key(kind: kind, token: token))
        lock.unlock()
    }

    func waitIfEnabled(_ kind: Kind, token: SessionToken) async {
        let key = Key(kind: kind, token: token)
        let shouldWait = locked { enabled.contains(key) }
        guard shouldWait else { return }

        await withCheckedContinuation { continuation in
            let resumeImmediately: Bool = locked {
                guard enabled.contains(key) else { return true }
                waiters[key, default: []].append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func release(_ kind: Kind, token: SessionToken) {
        let key = Key(kind: kind, token: token)
        let continuations: [CheckedContinuation<Void, Never>] = locked {
            enabled.remove(key)
            return waiters.removeValue(forKey: key) ?? []
        }
        continuations.forEach { $0.resume() }
    }

    func releaseAll() {
        let continuations: [CheckedContinuation<Void, Never>] = locked {
            enabled.removeAll()
            let continuations = waiters.values.flatMap { $0 }
            waiters.removeAll()
            return continuations
        }
        continuations.forEach { $0.resume() }
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

actor RecordingSessionOutput: DictationSessionOutput {
    private let gates: OutputGateBank
    private(set) var liveEvents: [DictationSessionEventEnvelope] = []
    private(set) var terminals: [(DictationTerminal, SessionToken)] = []
    private var commitStatuses: [SessionToken: DictationOutputCommitStatus] = [:]

    init(gates: OutputGateBank) {
        self.gates = gates
    }

    func setCommitStatus(_ status: DictationOutputCommitStatus, token: SessionToken) {
        commitStatuses[token] = status
    }

    func publishLive(
        _ envelope: DictationSessionEventEnvelope,
        request: DictationSessionRequest
    ) async {
        liveEvents.append(envelope)
        await gates.waitIfEnabled(.publishLive, token: request.token)
    }

    func commit(
        _ terminal: DictationTerminal,
        token: SessionToken
    ) async -> DictationOutputCommitStatus {
        terminals.append((terminal, token))
        await gates.waitIfEnabled(.commit, token: token)
        return commitStatuses[token] ?? .written
    }

    func commitCount(for token: SessionToken) -> Int {
        terminals.filter { $0.1 == token }.count
    }
}

final class EngineHarness: @unchecked Sendable {
    let deadlines: DictationSessionDeadlines
    let completedPlan: EditPlan
    let journal: TestOperationJournal
    let permissions: ManualPermissionResolver
    let audioSession: StubAudioSessionController
    let speech: ManualSpeechFactory
    let audio: ManualAudioCaptureFactory
    let scheduler: ManualDeadlineScheduler
    let processor: RecordingTextProcessor
    let outputGates: OutputGateBank
    let output: RecordingSessionOutput
    let engine: DictationSessionEngine

    init(permissionSuspended: Bool = false) {
        let deadlines = DictationSessionDeadlines(
            start: 4,
            silence: 3,
            finalRecognition: 0.45,
            processing: 5,
            partialPublish: 0.20,
            foregroundClaim: 3
        )
        let plan = EditPlan(
            intent: .dictate,
            operation: .insertAtCursor,
            text: "处理后文本",
            expectedContextFingerprint: nil,
            requiresConfirmation: false
        )
        let journal = TestOperationJournal()
        let permissions = ManualPermissionResolver(suspends: permissionSuspended)
        let audioSession = StubAudioSessionController(journal: journal)
        let speech = ManualSpeechFactory(journal: journal)
        let audio = ManualAudioCaptureFactory(journal: journal)
        let scheduler = ManualDeadlineScheduler()
        let processor = RecordingTextProcessor(result: .success(plan))
        let outputGates = OutputGateBank()
        let output = RecordingSessionOutput(gates: outputGates)

        self.deadlines = deadlines
        completedPlan = plan
        self.journal = journal
        self.permissions = permissions
        self.audioSession = audioSession
        self.speech = speech
        self.audio = audio
        self.scheduler = scheduler
        self.processor = processor
        self.outputGates = outputGates
        self.output = output
        engine = DictationSessionEngine(
            permissions: permissions,
            audioSession: audioSession,
            speechFactory: speech,
            audioFactory: audio,
            scheduler: scheduler,
            processor: processor,
            output: output,
            deadlines: deadlines
        )
    }

    func makeRequest(
        token: SessionToken = SessionToken(),
        entryPoint: DictationEntryPoint = .foreground,
        authorizationPolicy: DictationAuthorizationPolicy = .requestIfNeeded,
        whisper: Bool = false
    ) -> DictationSessionRequest {
        DictationSessionRequest(
            token: token,
            entryPoint: entryPoint,
            authorizationPolicy: authorizationPolicy,
            whisper: whisper,
            processing: TextProcessingSnapshot(
                selectedText: nil,
                keyboardType: 0,
                language: "zh-CN",
                translateEnabled: false,
                translateTarget: "en-US",
                voiceEditEnabled: true,
                livePreviewEnabled: true,
                expectedContextFingerprint: nil
            )
        )
    }

    func beginStart(_ request: DictationSessionRequest) -> PendingEngineStart {
        PendingEngineStart(engine: engine, request: request)
    }

    func start(
        _ request: DictationSessionRequest,
        timeout: TimeInterval = 1
    ) async throws -> EventStreamRecorder {
        let pending = beginStart(request)
        defer { pending.cancel() }
        return try await pending.waitForRecorder(timeout: timeout)
    }

    func waitForSpeechSessionCount(_ expected: Int) async throws {
        try await waitUntil("\(expected) Speech sessions") {
            self.speech.sessionCount == expected
        }
    }

    func waitForAudioCaptureSessionCount(_ expected: Int) async throws {
        try await waitUntil("\(expected) audio capture sessions") {
            self.audio.sessionCount == expected
        }
    }

    func waitForEvent(
        _ event: DictationSessionEvent,
        in recorder: EventStreamRecorder
    ) async throws {
        try await waitUntil("event \(event)") {
            recorder.events.contains { $0.event == event }
        }
    }

    func waitForFinished(_ recorder: EventStreamRecorder) async throws {
        try await waitUntil("event stream finish") {
            recorder.isFinished
        }
    }

    func releaseAllTestWaiters() {
        outputGates.releaseAll()
        permissions.releaseForCleanup()
    }
}
