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

    func testHotTimeoutSendsCancelWhenOldRunnerIsAlreadyProcessing() async throws {
        let old = store()
        let manual = SessionToken()
        let original = try XCTUnwrap(DarwinBridge.peekDictationSettings(expectedSession: old.rawValue))
        let runner = runner([.preparing, .processing])
        let pip = RecordingPiPStandbyPresenter(isActive: true)
        let manager = BackgroundDictationManager(engine: runner, pip: pip)
        try await start(manager)
        try await waitUntil("old runner processing") { pip.states.last == .processing("") }
        guard case .moved = DarwinBridge.handoffDictationSettingsToManual(
            from: old, to: manual, original: original) else {
            return XCTFail("Expected manual handoff after old settings were consumed")
        }
        try await runBoundedOperation("dedicated cancel reaches processing runner") {
            await manager.handleCancelNotification(session: old.rawValue)
        }
        let cancelled = await runner.cancelledTokens
        let stopped = await runner.stoppedTokens
        XCTAssertEqual(cancelled, [old])
        XCTAssertTrue(stopped.isEmpty)
        XCTAssertEqual(DarwinBridge.commit(.failed(.recognition), token: old), .cancelled)
        XCTAssertEqual(DarwinBridge.peekDictationSettings(expectedSession: manual.rawValue)?.session, manual.rawValue)
        await runner.finishAllStreams()
    }

    func testPersistedCancellationWithoutNotificationStopsListeningAndProcessingOwner() async throws {
        let phases: [[DictationSessionEvent]] = [[.listening(partial: "live")], [.preparing, .processing]]
        for events in phases {
            let token = store()
            let runner = runner(events)
            let pip = RecordingPiPStandbyPresenter(isActive: true)
            let manager = BackgroundDictationManager(engine: runner, pip: pip)
            defer { withExtendedLifetime(manager) {} }
            try await start(manager)
            try await waitUntil("active owner presentation") { !pip.states.isEmpty }

            // Simulate eviction after durable cancellation and before the dedicated notification.
            // cancelSession posts only live-state notification; this test never calls the cancel adapter.
            XCTAssertTrue(DarwinBridge.cancelSession(token.rawValue))
            try await waitUntil("durable cancellation reaches current runner without notification", timeout: 2) {
                await runner.cancelledTokens == [token]
            }
            let owner = await runner.owner
            let stops = await runner.stoppedTokens
            XCTAssertNil(owner)
            XCTAssertTrue(stops.isEmpty)
            try await requireStableCondition("durable cancellation is forwarded once", duration: 0.6) {
                await runner.cancelledTokens == [token]
            }
            await runner.finishAllStreams()
        }
    }

    func testPersistedCancellationBeforeAdmissionCancelsAfterStartReturnsWithoutRendering() async throws {
        let token = store()
        let runner = runner([.listening(partial: "must not render")])
        let pip = RecordingPiPStandbyPresenter(isActive: true)
        let manager = BackgroundDictationManager(engine: runner, pip: pip)
        runner.startGates.enable(.commit, token: token)
        let returned = LockedTestBox(false)
        let task = Task { await manager.handlePendingRequest(); returned.set(true) }
        defer { runner.startGates.releaseAll(); task.cancel() }
        try await waitUntil("gated start entered") { await runner.requests.count == 1 }
        XCTAssertTrue(DarwinBridge.cancelSession(token.rawValue))
        try await requireStableCondition("no ineffective cancellation before admission", duration: 0.6) {
            await runner.cancelledTokens.isEmpty
        }
        runner.startGates.releaseAll()
        try await waitUntil("post-admission durable cancellation", timeout: 2) {
            let cancelled = await runner.cancelledTokens
            return returned.value && cancelled == [token]
        }
        let owner = await runner.owner
        XCTAssertNil(owner)
        XCTAssertTrue(pip.states.isEmpty, "Canceled admission must not briefly present buffered listening events")
        await runner.finishAllStreams()
    }

    func testOldCancellationReconciliationCannotCancelReplacementAndTracksItsNewTombstone() async throws {
        let runner = runner([.listening(partial: "live")])
        let pip = RecordingPiPStandbyPresenter(isActive: true)
        let manager = BackgroundDictationManager(engine: runner, pip: pip)
        defer { withExtendedLifetime(manager) {} }
        let old = store()
        try await start(manager)
        try await waitUntil("old owner active") { await runner.owner == old }
        XCTAssertTrue(DarwinBridge.cancelSession(old.rawValue))
        let replacement = store()
        try await start(manager)
        await runner.send(.listening(partial: "replacement"), token: replacement)
        try await waitUntil("replacement visible") { pip.states.last == .recording("replacement") }
        try await requireStableCondition("old polling cannot touch the replacement", duration: 1.1) {
            let cancelled = await runner.cancelledTokens
            let owner = await runner.owner
            return !cancelled.contains(replacement) && owner == replacement
                && pip.states.last == .recording("replacement")
        }
        XCTAssertTrue(DarwinBridge.cancelSession(replacement.rawValue))
        try await waitUntil("replacement tombstone is independently reconciled", timeout: 2) {
            await runner.cancelledTokens.filter { $0 == replacement }.count == 1
        }
        let stops = await runner.stoppedTokens
        XCTAssertTrue(stops.isEmpty)
        await runner.finishAllStreams()
    }

    func testUnavailableCancellationStorageConservativelyCancelsCurrentOwner() async throws {
        let token = store()
        let runner = runner([.listening(partial: "live")])
        let pip = RecordingPiPStandbyPresenter(isActive: true)
        let manager = BackgroundDictationManager(engine: runner, pip: pip)
        defer { withExtendedLifetime(manager) {} }
        try await start(manager)
        try await waitUntil("owner admitted before storage loss") { await runner.owner == token }
        DarwinBridge.setContainerDirectoryForTesting(nil)
        defer { DarwinBridge.setContainerDirectoryForTesting(directory) }
        try await waitUntil("unavailable storage fails closed for active owner", timeout: 2) {
            await runner.cancelledTokens == [token]
        }
        let owner = await runner.owner
        XCTAssertNil(owner)
        await runner.finishAllStreams()
    }

    func testCancelNotificationDuringStartDefersEffectiveForwardUntilAdmission() async throws {
        let token = store()
        let runner = runner([.listening(partial: "must not render")])
        let pip = RecordingPiPStandbyPresenter(isActive: true)
        let manager = BackgroundDictationManager(engine: runner, pip: pip)
        runner.startGates.enable(.commit, token: token)
        let returned = LockedTestBox(false)
        let task = Task { await manager.handlePendingRequest(); returned.set(true) }
        defer { runner.startGates.releaseAll(); task.cancel() }
        try await waitUntil("start entered before dedicated cancel") { await runner.requests.count == 1 }
        try await runBoundedOperation("pre-admission cancel notification returns") {
            await manager.handleCancelNotification(session: token.rawValue)
        }
        let beforeAdmission = await runner.cancelledTokens
        XCTAssertTrue(beforeAdmission.isEmpty, "Sending cancel before the runner owns this token is ineffective")
        runner.startGates.releaseAll()
        try await waitUntil("deferred notification cancels admitted owner", timeout: 2) {
            let cancelled = await runner.cancelledTokens
            let owner = await runner.owner
            return returned.value && cancelled == [token] && owner == nil
        }
        XCTAssertTrue(pip.states.isEmpty)
        await runner.finishAllStreams()
    }

    func testCancellationDoesNotPublishStandbyUntilCaptureReleaseCompletes() async throws {
        let token = store()
        let runner = runner([.listening(partial: "held capture")])
        let pip = RecordingPiPStandbyPresenter(isActive: true)
        let manager = BackgroundDictationManager(engine: runner, pip: pip)
        try await start(manager)
        try await waitUntil("capture presented before cancel") { pip.states == [.recording("held capture")] }
        runner.cancelGates.enable(.commit, token: token)
        let returned = LockedTestBox(false)
        let task = Task { await manager.handleCancelNotification(session: token.rawValue); returned.set(true) }
        defer { runner.cancelGates.releaseAll(); task.cancel() }
        try await waitUntil("cancel reached capture release gate") { await runner.cancelledTokens == [token] }
        let heldOwner = await runner.owner
        XCTAssertEqual(heldOwner, token)
        XCTAssertFalse(returned.value)
        XCTAssertEqual(pip.states, [.recording("held capture")],
                       "Standby must not claim capture release while cancellation is suspended")

        runner.cancelGates.releaseAll()
        try await waitUntil("cancel completes before standby") { returned.value && pip.states.last == .standby }
        let releasedOwner = await runner.owner
        XCTAssertNil(releasedOwner)
        XCTAssertEqual(pip.states, [.recording("held capture"), .standby])
        await runner.finishAllStreams()
    }

    func testHeldOldCancellationCannotPublishStandbyOverActiveSuccessor() async throws {
        let old = store()
        let runner = runner([.listening(partial: "initial")])
        let pip = RecordingPiPStandbyPresenter(isActive: true)
        let manager = BackgroundDictationManager(engine: runner, pip: pip)
        try await start(manager)
        try await waitUntil("old capture presented") { pip.states == [.recording("initial")] }
        runner.cancelGates.enable(.commit, token: old)
        let returned = LockedTestBox(false)
        let task = Task { await manager.handleCancelNotification(session: old.rawValue); returned.set(true) }
        defer { runner.cancelGates.releaseAll(); task.cancel() }
        try await waitUntil("old cancel held") { await runner.cancelledTokens == [old] }
        XCTAssertEqual(pip.states, [.recording("initial")], "Held cancellation cannot publish standby early")

        let replacement = store()
        try await start(manager)
        await runner.send(.listening(partial: "replacement"), token: replacement)
        try await waitUntil("successor presented before old release") { pip.states.last == .recording("replacement") }
        let successorStates = pip.states
        runner.cancelGates.releaseAll()
        try await waitUntil("old cancellation returned") { returned.value }
        let owner = await runner.owner
        XCTAssertEqual(owner, replacement)
        XCTAssertEqual(pip.states, successorStates, "Old cancellation cannot repaint a successor")
        await runner.finishAllStreams()
    }

    func testHeldOldCancellationCannotPublishStandbyAfterSuccessorHasTerminated() async throws {
        let old = store()
        let runner = runner([.listening(partial: "initial")])
        let pip = RecordingPiPStandbyPresenter(isActive: true)
        let manager = BackgroundDictationManager(engine: runner, pip: pip)
        try await start(manager)
        try await waitUntil("old capture presented") { pip.states == [.recording("initial")] }
        runner.cancelGates.enable(.commit, token: old)
        let returned = LockedTestBox(false)
        let task = Task { await manager.handleCancelNotification(session: old.rawValue); returned.set(true) }
        defer { runner.cancelGates.releaseAll(); task.cancel() }
        try await waitUntil("old cancel held") { await runner.cancelledTokens == [old] }
        XCTAssertEqual(pip.states, [.recording("initial")], "Held cancellation cannot publish standby early")

        let replacement = store()
        try await start(manager)
        await runner.send(.completed(plan), token: replacement)
        try await waitUntil("successor terminal presented") {
            pip.states.count >= 3 && pip.states.last == .standby
        }
        let terminalStates = pip.states
        let terminalStateCount = pip.states.count
        runner.cancelGates.releaseAll()
        try await waitUntil("old cancellation returned after successor terminal") { returned.value }
        XCTAssertEqual(pip.states.count, terminalStateCount,
                       "A nil current token after successor terminal is not permission for old standby")
        XCTAssertEqual(pip.states, terminalStates)
        await runner.finishAllStreams()
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
