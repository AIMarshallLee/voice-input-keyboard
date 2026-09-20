import XCTest
@testable import VoiceInputApp

@MainActor
final class BackgroundDictationManagerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        DarwinBridge.setContainerDirectoryForTesting(directory)
    }

    override func tearDownWithError() throws {
        DarwinBridge.resetContainerDirectoryAfterTesting()
        try FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private var plan: EditPlan {
        EditPlan(intent: .dictate, operation: .insertAtCursor, text: "你好。",
                 expectedContextFingerprint: nil, requiresConfirmation: false)
    }

    @discardableResult
    private func store(_ token: SessionToken = SessionToken()) -> SessionToken {
        let settings = DictationSettings(language: "zh-CN", whisper: false,
            translateEnabled: false, translateTarget: "en-US", selectedText: nil,
            keyboardType: 0, session: token.rawValue)
        XCTAssertTrue(DarwinBridge.writeDictationSettings(settings))
        return token
    }

    private func runner(_ events: [DictationSessionEvent], finishes: Bool = false) -> RecordingSessionRunner {
        let runner = RecordingSessionRunner(events: events, finishesStream: finishes)
        addTeardownBlock { await runner.finishAllStreams() }
        return runner
    }

    private func start(_ manager: BackgroundDictationManager) async throws {
        try await runBoundedOperation("adapter installs event consumer") {
            await manager.handlePendingRequest()
        }
    }

    func testHotRequestUsesReadOnlyPolicyAndMirrorsEngineEvents() async throws {
        let runner = runner([.preparing, .listening(partial: "你好"), .processing, .completed(plan)], finishes: true)
        let pip = RecordingPiPStandbyPresenter(isActive: true)
        let manager = BackgroundDictationManager(engine: runner, pip: pip)
        let token = store()
        try await start(manager)
        try await waitUntil("terminal presentation") { pip.states.last == .standby }
        let requests = await runner.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.token, token)
        XCTAssertEqual(request.entryPoint, .inPlace)
        XCTAssertEqual(request.authorizationPolicy, .readOnly)
        XCTAssertEqual(request.processing.language, "zh-CN")
        XCTAssertEqual(request.processing.translateTarget, "en-US")
        XCTAssertEqual(pip.states, [.recording("你好"), .processing("你好"), .standby])
        XCTAssertNil(DarwinBridge.peekDictationSettings(expectedSession: token.rawValue))
    }

    func testInactivePiPLeavesPendingRequestUnconsumed() async throws {
        let runner = runner([.preparing])
        let pip = RecordingPiPStandbyPresenter(isActive: false)
        let manager = BackgroundDictationManager(engine: runner, pip: pip)
        let token = store()
        try await start(manager)
        let requests = await runner.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(DarwinBridge.peekPendingDictationSettings()?.session, token.rawValue)
        XCTAssertNotNil(DarwinBridge.peekDictationSettings(expectedSession: token.rawValue))
    }

    func testPreparingDoesNotDisplayRecordingBeforeListening() async throws {
        let runner = runner([.preparing])
        let pip = RecordingPiPStandbyPresenter(isActive: true)
        let manager = BackgroundDictationManager(engine: runner, pip: pip)
        let token = store()
        let acknowledged = LockedTestBox(false)
        let name = try XCTUnwrap(DarwinBridge.sessionNotificationName(
            base: DarwinNotificationName.dictationStarted, session: token.rawValue))
        let observer = DarwinNotificationObserver(name: name) { acknowledged.set(true) }
        defer { withExtendedLifetime(observer) {} }
        try await start(manager)
        try await requireStableCondition("preparing must not claim microphone recording") { pip.states.isEmpty }
        try await waitUntil("session-scoped hot acknowledgement before listening") { acknowledged.value }
        await runner.send(.listening(partial: "ready"), token: token)
        try await waitUntil("listening presentation") { pip.states == [.recording("ready")] }
    }

    func testStopForwardsOnlyMatchingTokenOnHeldOpenStream() async throws {
        let runner = runner([.listening(partial: "")])
        let pip = RecordingPiPStandbyPresenter(isActive: true)
        let manager = BackgroundDictationManager(engine: runner, pip: pip)
        let token = store()
        try await start(manager)
        try await waitUntil("listening") { pip.states.count == 1 }
        await manager.handleStopNotification(session: UUID().uuidString)
        await manager.handleStopNotification(session: token.rawValue)
        let stops = await runner.stoppedTokens
        let cancels = await runner.cancelledTokens
        XCTAssertEqual(stops, [token])
        XCTAssertTrue(cancels.isEmpty)
    }

    func testCancelForwardsOnlyMatchingTokenWhileProcessing() async throws {
        let runner = runner([.listening(partial: "text"), .processing])
        let pip = RecordingPiPStandbyPresenter(isActive: true)
        let manager = BackgroundDictationManager(engine: runner, pip: pip)
        let token = store()
        try await start(manager)
        try await waitUntil("processing") { pip.states.last == .processing("text") }
        await manager.handleCancelNotification(session: UUID().uuidString)
        await manager.handleCancelNotification(session: token.rawValue)
        let stops = await runner.stoppedTokens
        let cancels = await runner.cancelledTokens
        XCTAssertTrue(stops.isEmpty)
        XCTAssertEqual(cancels, [token])
    }

    func testStopDuringProcessingDoesNotTurnIntoCancel() async throws {
        let runner = runner([.listening(partial: "text"), .processing])
        let pip = RecordingPiPStandbyPresenter(isActive: true)
        let manager = BackgroundDictationManager(engine: runner, pip: pip)
        let token = store()
        try await start(manager)
        try await waitUntil("processing") { pip.states.last == .processing("text") }
        await manager.handleStopNotification(session: token.rawValue)
        let stops = await runner.stoppedTokens
        let cancels = await runner.cancelledTokens
        XCTAssertEqual(stops, [token])
        XCTAssertTrue(cancels.isEmpty)
    }

    func testTerminalDetachesTokenBeforeLaterCommandsOrPiPStop() async throws {
        let runner = runner([.listening(partial: "done"), .completed(plan)], finishes: true)
        let pip = RecordingPiPStandbyPresenter(isActive: true)
        let manager = BackgroundDictationManager(engine: runner, pip: pip)
        let token = store()
        try await start(manager)
        try await waitUntil("terminal presentation") { pip.states.last == .standby }
        await manager.handleStopNotification(session: token.rawValue)
        await manager.handleCancelNotification(session: token.rawValue)
        pip.stopStandby()
        try await requireStableCondition("no command after terminal") {
            let stops = await runner.stoppedTokens
            let cancels = await runner.cancelledTokens
            return stops.isEmpty && cancels.isEmpty
        }
    }

    func testPreListeningFailuresConsumeWithoutRequeueOrDuplicateCancel() async throws {
        let failures: [DictationFailure] = [.permissionRequiresForeground(.microphone), .recognitionUnavailable, .startTimeout]
        for failure in failures {
            let runner = runner([.failed(failure)], finishes: true)
            let pip = RecordingPiPStandbyPresenter(isActive: true)
            let manager = BackgroundDictationManager(engine: runner, pip: pip)
            let token = store()
            try await start(manager)
            try await waitUntil("readiness disabled") { pip.stopStandbyCount == 1 }
            XCTAssertNil(DarwinBridge.peekDictationSettings(expectedSession: token.rawValue))
            XCTAssertNil(DarwinBridge.peekPendingDictationSettings())
            try await requireStableCondition("terminal must not trigger cancel callback") {
                await runner.cancelledTokens.isEmpty
            }
        }
    }

    func testUnexpectedNonterminalEOFFailsClosedAndCancelsExactlyOnce() async throws {
        let runner = runner([.listening(partial: "unfinished")], finishes: true)
        let pip = RecordingPiPStandbyPresenter(isActive: true)
        let manager = BackgroundDictationManager(engine: runner, pip: pip)
        let token = store()
        try await start(manager)
        try await waitUntil("EOF cancels") { await runner.cancelledTokens == [token] }
        XCTAssertFalse(pip.isActive)
        XCTAssertEqual(pip.stopStandbyCount, 1)
        await manager.handleStopNotification(session: token.rawValue)
        let stops = await runner.stoppedTokens
        XCTAssertTrue(stops.isEmpty)
        try await requireStableCondition("EOF cancellation is unique") { await runner.cancelledTokens == [token] }
    }

    func testPiPLossCancelsListeningAndProcessingExactlyOnce() async throws {
        for processing in [false, true] {
            let events: [DictationSessionEvent] = processing ? [.listening(partial: "text"), .processing] : [.listening(partial: "text")]
            let runner = runner(events)
            let pip = RecordingPiPStandbyPresenter(isActive: true)
            let manager = BackgroundDictationManager(engine: runner, pip: pip)
            let token = store()
            try await start(manager)
            try await waitUntil("phase presentation") { pip.states.count == events.count }
            let callback = try XCTUnwrap(pip.onStandbyStopped)
            pip.stopStandby()
            callback()
            try await waitUntil("PiP loss cancellation") { await runner.cancelledTokens == [token] }
            await manager.handleStopNotification(session: token.rawValue)
            let stops = await runner.stoppedTokens
            XCTAssertTrue(stops.isEmpty)
            await runner.send(.completed(plan), token: token)
            try await requireStableCondition("late terminal must not revive PiP") {
                pip.states.count == events.count
            }
            let cancels = await runner.cancelledTokens
            XCTAssertEqual(cancels, [token])
        }
    }

    func testPiPLossDuringGatedStartDefersEffectiveCancelUntilAdmission() async throws {
        let runner = runner([.listening(partial: "late")])
        let pip = RecordingPiPStandbyPresenter(isActive: true)
        let manager = BackgroundDictationManager(engine: runner, pip: pip)
        let token = store()
        runner.startGates.enable(.commit, token: token)
        let finished = LockedTestBox(false)
        let task = Task { await manager.handlePendingRequest(); finished.set(true) }
        defer { runner.startGates.releaseAll(); task.cancel() }
        try await waitUntil("start entered") { await runner.requests.count == 1 }
        pip.stopStandby()
        try await requireStableCondition("no ineffective pre-admission cancel") { await runner.cancelledTokens.isEmpty }
        runner.startGates.releaseAll()
        try await waitUntil("start return and deferred cancellation") {
            let cancels = await runner.cancelledTokens
            return finished.value && cancels == [token]
        }
        let owner = await runner.owner
        XCTAssertNil(owner)
        XCTAssertTrue(pip.states.isEmpty)
        try await requireStableCondition("exactly one deferred cancel") { await runner.cancelledTokens == [token] }
    }

    func testPendingBSerializesBehindGatedAAndRejectsLateAAndSavedCallback() async throws {
        let runner = runner([.listening(partial: "current")])
        let pip = RecordingPiPStandbyPresenter(isActive: true)
        let manager = BackgroundDictationManager(engine: runner, pip: pip)
        let a = store()
        runner.startGates.enable(.commit, token: a)
        let finished = LockedTestBox(false)
        let task = Task { await manager.handlePendingRequest(); finished.set(true) }
        defer { runner.startGates.releaseAll(); task.cancel() }
        try await waitUntil("A entered") { await runner.requests.count == 1 }
        let oldCallback = try XCTUnwrap(pip.onStandbyStopped)
        let b = store()
        try await start(manager)
        try await requireStableCondition("B cannot start concurrently with A") { await runner.requests.count == 1 }
        runner.startGates.releaseAll()
        try await waitUntil("B admitted after A") { await runner.admittedTokens == [a, b] }
        try await waitUntil("drain returned") { finished.value }
        await runner.send(.listening(partial: "B"), token: b)
        try await waitUntil("B visible") { pip.states.last == .recording("B") }
        let before = pip.states
        oldCallback()
        await runner.send(.listening(partial: "stale A"), token: a)
        await runner.send(.failed(.startTimeout), token: b, envelopeToken: a)
        await runner.finish(token: a)
        try await requireStableCondition("late A cannot alter B presentation") { pip.states == before && pip.isActive }
        await manager.handleStopNotification(session: a.rawValue)
        await manager.handleStopNotification(session: b.rawValue)
        let stops = await runner.stoppedTokens
        let owner = await runner.owner
        let cancels = await runner.cancelledTokens
        XCTAssertEqual(stops, [b])
        XCTAssertEqual(owner, b)
        XCTAssertFalse(cancels.contains(b))
    }

    func testRealEnginePermissionFailurePersistsTerminalReceiptAndRejectsLaterCommit() async throws {
        let harness = EngineHarness()
        defer { harness.releaseAllTestWaiters() }
        harness.permissions.setResult(.failure(.permissionRequiresForeground(.microphone)))
        let engine = DictationSessionEngine(permissions: harness.permissions,
            audioSession: harness.audioSession, speechFactory: harness.speech,
            audioFactory: harness.audio, scheduler: harness.scheduler,
            processor: harness.processor, output: DarwinDictationSessionOutput())
        let pip = RecordingPiPStandbyPresenter(isActive: true)
        let manager = BackgroundDictationManager(engine: engine, pip: pip)
        let token = store()
        addTeardownBlock { await engine.cancel(token: token) }
        try await start(manager)
        try await waitUntil("persisted failure and disabled readiness") {
            DarwinBridge.peekResult(expectedSession: token.rawValue)?.status == .error && pip.stopStandbyCount == 1
        }
        XCTAssertEqual(harness.permissions.policies, [.readOnly])
        XCTAssertEqual(harness.audio.sessionCount, 0)
        XCTAssertEqual(harness.speech.sessionCount, 0)
        XCTAssertNil(DarwinBridge.peekDictationSettings(expectedSession: token.rawValue))
        XCTAssertNil(DarwinBridge.peekPendingDictationSettings())
        XCTAssertEqual(DarwinBridge.commit(.completed(plan), token: token), .alreadyTerminal)
        XCTAssertEqual(DarwinBridge.peekResult(expectedSession: token.rawValue)?.status, .error)
        XCTAssertEqual(DarwinBridge.readAndConsumeResult(expectedSession: token.rawValue)?.status, .error)
        XCTAssertNil(DarwinBridge.peekResult(expectedSession: token.rawValue))
        XCTAssertEqual(DarwinBridge.commit(.completed(plan), token: token), .alreadyTerminal)
        XCTAssertNil(DarwinBridge.peekResult(expectedSession: token.rawValue))
    }
}
