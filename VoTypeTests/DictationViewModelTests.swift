import XCTest
@testable import VoiceInputApp

final class DictationViewModelTests: XCTestCase {
    private var ipcDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        ipcDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoTypeViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: ipcDirectory,
            withIntermediateDirectories: true
        )
        DarwinBridge.setContainerDirectoryForTesting(ipcDirectory)
    }

    override func tearDownWithError() throws {
        DarwinBridge.clearIPCFilesForTesting()
        DarwinBridge.resetContainerDirectoryAfterTesting()
        if let ipcDirectory {
            try? FileManager.default.removeItem(at: ipcDirectory)
        }
        try super.tearDownWithError()
    }

    private func writeSettings(
        session: String,
        language: String = "zh-CN",
        whisper: Bool = false,
        translateEnabled: Bool = false,
        translateTarget: String = "en-US",
        selectedText: String? = nil,
        keyboardType: Int = 0
    ) {
        XCTAssertTrue(
            DarwinBridge.writeDictationSettings(
                DictationSettings(
                    language: language,
                    whisper: whisper,
                    translateEnabled: translateEnabled,
                    translateTarget: translateTarget,
                    selectedText: selectedText,
                    keyboardType: keyboardType,
                    session: session
                )
            )
        )
    }

    func testLoadSettingsFromURL() async {
        await MainActor.run {
            let session = UUID().uuidString
            writeSettings(session: session, language: "en-US", whisper: true)
            let url = DictationConstants.buildDictationURL(session: session)
            let viewModel = DictationViewModel()
            viewModel.loadSettings(from: url)

            XCTAssertTrue(viewModel.hasValidSettings)
            XCTAssertEqual(viewModel.languageID, "en-US")
            XCTAssertTrue(viewModel.whisperMode)
            XCTAssertFalse(viewModel.translateEnabled)
            XCTAssertEqual(viewModel.translateTarget, "en-US")
            XCTAssertNil(viewModel.selectedText)
            XCTAssertEqual(viewModel.keyboardType, 0)
            XCTAssertEqual(viewModel.sessionId, session)
            XCTAssertNotNil(DarwinBridge.peekDictationSettings(expectedSession: session))
            XCTAssertNil(DarwinBridge.readLiveState(expectedSession: session))
            viewModel.cleanup()
        }
    }

    func testLoadSettingsFromNilURL() async {
        await MainActor.run {
            let session = UUID().uuidString
            writeSettings(session: session, language: "ja-JP")
            let viewModel = DictationViewModel()
            viewModel.loadSettings(from: nil)
            XCTAssertTrue(viewModel.hasValidSettings)
            XCTAssertEqual(viewModel.sessionId, session)
            XCTAssertEqual(viewModel.languageID, "ja-JP")
        }
    }

    func testExplicitPresentationSessionCannotConsumeNewerRequest() async {
        await MainActor.run {
            let queuedSession = UUID().uuidString
            let newerSession = UUID().uuidString
            let now = Date().timeIntervalSince1970
            XCTAssertTrue(
                DarwinBridge.writeDictationSettings(
                    DictationSettings(
                        language: "ja-JP",
                        whisper: false,
                        translateEnabled: false,
                        translateTarget: "en-US",
                        selectedText: nil,
                        keyboardType: 0,
                        session: queuedSession,
                        timestamp: now
                    )
                )
            )
            XCTAssertTrue(
                DarwinBridge.writeDictationSettings(
                    DictationSettings(
                        language: "en-US",
                        whisper: false,
                        translateEnabled: false,
                        translateTarget: "zh-CN",
                        selectedText: nil,
                        keyboardType: 0,
                        session: newerSession,
                        timestamp: now + 1
                    )
                )
            )

            let viewModel = DictationViewModel()
            viewModel.loadSettings(
                from: nil,
                expectedSession: queuedSession
            )

            XCTAssertTrue(viewModel.hasValidSettings)
            XCTAssertEqual(viewModel.sessionId, queuedSession)
            XCTAssertEqual(viewModel.languageID, "ja-JP")
            XCTAssertEqual(
                DarwinBridge.peekPendingDictationSettings(now: now + 1)?.session,
                newerSession
            )
        }
    }

    func testLoadSettingsWithSelectedText() async {
        await MainActor.run {
            let session = UUID().uuidString
            writeSettings(
                session: session,
                selectedText: "hello",
                keyboardType: 7
            )
            let url = DictationConstants.buildDictationURL(session: session)
            let viewModel = DictationViewModel()
            viewModel.loadSettings(from: url)

            XCTAssertEqual(viewModel.selectedText, "hello")
            XCTAssertEqual(viewModel.keyboardType, 7)
            XCTAssertEqual(viewModel.sessionId, session)
        }
    }

    func testLoadSettingsWithTranslate() async {
        await MainActor.run {
            let session = UUID().uuidString
            writeSettings(
                session: session,
                translateEnabled: true,
                translateTarget: "en-US"
            )
            let url = DictationConstants.buildDictationURL(session: session)
            let viewModel = DictationViewModel()
            viewModel.loadSettings(from: url)

            XCTAssertTrue(viewModel.translateEnabled)
            XCTAssertEqual(viewModel.translateTarget, "en-US")
            XCTAssertEqual(viewModel.languageID, "zh-CN")
        }
    }

    func testURLCannotSupplySettingsWithoutAppGroupRequest() async {
        await MainActor.run {
            let url = DictationConstants.buildDictationURL(session: UUID().uuidString)
            let viewModel = DictationViewModel()
            viewModel.loadSettings(from: url)

            XCTAssertFalse(viewModel.hasValidSettings)
            XCTAssertEqual(viewModel.sessionId, "")
        }
    }

    @MainActor
    func testStopRecordingWithoutStart() async {
        let runner = makeRunner([])
        let viewModel = DictationViewModel(engine: runner)
        await viewModel.stopRecording()
        await viewModel.cancelRecording()
        let stops = await runner.stoppedTokens
        let cancels = await runner.cancelledTokens
        XCTAssertTrue(stops.isEmpty)
        XCTAssertTrue(cancels.isEmpty)
    }

    func testCleanupWithoutStart() async {
        await MainActor.run {
            let viewModel = DictationViewModel()
            viewModel.cleanup()
        }
    }

    private func makeRunner(_ events: [DictationSessionEvent], finishes: Bool = false) -> RecordingSessionRunner {
        let runner = RecordingSessionRunner(events: events, finishesStream: finishes)
        addTeardownBlock { await runner.finishAllStreams() }
        return runner
    }

    private func settings(_ token: SessionToken) -> DictationSettings {
        DictationSettings(language: "ja-JP", whisper: true, translateEnabled: true,
            translateTarget: "en-US", selectedText: "selection", keyboardType: 7,
            session: token.rawValue, expectedContextFingerprint: "context-fingerprint")
    }

    private var plan: EditPlan {
        EditPlan(intent: .dictate, operation: .insertAtCursor, text: "你好。",
            expectedContextFingerprint: nil, requiresConfirmation: false)
    }

    @MainActor
    private func load(_ model: DictationViewModel, token: SessionToken) {
        XCTAssertTrue(DarwinBridge.writeDictationSettings(settings(token)))
        model.loadSettings(from: nil, expectedSession: token.rawValue)
    }

    @MainActor
    private func begin(_ model: DictationViewModel) -> Task<Void, Never> {
        let task = Task { await model.startRecording() }
        addTeardownBlock {
            task.cancel()
            await MainActor.run { model.cleanup() }
        }
        return task
    }

    @MainActor
    func testStartClaimsBeforeEngineAndMirrorsForegroundEventsWithCompleteSnapshot() async throws {
        let token = SessionToken()
        let runner = makeRunner([.authorizing, .preparing, .listening(partial: "你好"), .processing, .completed(plan)], finishes: true)
        let model = DictationViewModel(engine: runner)
        let stored = settings(token)
        let voiceEdit = TextProcessor.shared.voiceEditEnabled
        let livePreview = TextProcessor.shared.livePreviewEnabled
        XCTAssertTrue(DarwinBridge.writeDictationSettings(stored))
        model.loadSettings(from: nil, expectedSession: token.rawValue)
        XCTAssertEqual(DarwinBridge.peekDictationSettings(expectedSession: token.rawValue), stored)
        try await runBoundedOperation("foreground completion") { await model.startRecording() }
        let requests = await runner.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request, DictationSessionRequest(token: token, entryPoint: .foreground,
            authorizationPolicy: .requestIfNeeded, whisper: true,
            processing: TextProcessingSnapshot(selectedText: "selection", keyboardType: 7,
                language: "ja-JP", translateEnabled: true, translateTarget: "en-US",
                voiceEditEnabled: voiceEdit, livePreviewEnabled: livePreview,
                expectedContextFingerprint: "context-fingerprint")))
        let pendingAtStart = await runner.settingsPresentAtStart
        XCTAssertEqual(pendingAtStart, [false], "Claim must precede engine entry, even before authorizing is delivered")
        XCTAssertEqual(model.liveText, "你好")
        XCTAssertTrue(model.hasResult)
        XCTAssertEqual(model.statusMessage, "识别完成 ✓")
        XCTAssertNil(DarwinBridge.peekDictationSettings(expectedSession: token.rawValue))
    }

    @MainActor
    func testClaimPrecedesHeldHandshakeAndCancelledDeadlineCannotExpireOwnedRequest() async throws {
        let runner = makeRunner([])
        let scheduler = ManualDeadlineScheduler()
        let model = DictationViewModel(engine: runner, scheduler: scheduler, deadlines: .production)
        let token = SessionToken()
        load(model, token: token)
        let deadline = try XCTUnwrap(scheduler.pending.first)
        let task = begin(model)
        defer { task.cancel(); model.cleanup() }
        try await waitUntil("engine admission without handshake") { await runner.admittedTokens == [token] }
        XCTAssertNil(DarwinBridge.peekDictationSettings(expectedSession: token.rawValue))
        deadline.action()
        await runner.send(.authorizing, token: token)
        await runner.send(.listening(partial: "owned"), token: token)
        try await waitUntil("claimed request survives stale deadline") { model.liveText == "owned" }
        XCTAssertNil(model.permissionError)
        XCTAssertTrue(deadline.task.isCancelled)
    }

    @MainActor
    func testForegroundClaimTimeoutLeavesSettingsPendingAndNeverStartsEngine() async throws {
        let token = SessionToken()
        let runner = makeRunner([.authorizing])
        let scheduler = ManualDeadlineScheduler()
        let model = DictationViewModel(engine: runner, scheduler: scheduler, deadlines: .production)
        defer { model.cleanup() }
        let stored = settings(token)
        XCTAssertTrue(DarwinBridge.writeDictationSettings(stored))
        model.loadSettings(from: nil, expectedSession: token.rawValue)
        XCTAssertEqual(DictationSessionDeadlines.production.foregroundClaim, 3)
        XCTAssertEqual(scheduler.pending.map(\.interval), [3])
        scheduler.fire(interval: 3)
        try await waitUntil("claim deadline handled") { model.permissionError != nil }
        await model.startRecording()
        let requests = await runner.requests
        let cancels = await runner.cancelledTokens
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(cancels.isEmpty)
        XCTAssertEqual(model.permissionError, "未能启动该语音请求，请返回键盘重试")
        XCTAssertTrue(model.canExit)
        XCTAssertEqual(DarwinBridge.peekDictationSettings(expectedSession: token.rawValue), stored)
    }

    @MainActor
    func testLostOrMutatedExactClaimNeverStartsOrCancelsEngine() async throws {
        for mutate in [false, true] {
            let runner = makeRunner([.authorizing])
            let model = DictationViewModel(engine: runner)
            defer { model.cleanup() }
            let token = SessionToken()
            load(model, token: token)
            XCTAssertNotNil(DarwinBridge.readAndConsumeDictationSettings(expectedSession: token.rawValue))
            if mutate { writeSettings(session: token.rawValue, language: "fr-FR") }
            await model.startRecording()
            let requests = await runner.requests
            let cancels = await runner.cancelledTokens
            XCTAssertTrue(requests.isEmpty)
            XCTAssertTrue(cancels.isEmpty)
            XCTAssertEqual(model.permissionError, "该语音请求已由另一入口处理，请返回键盘重试")
            XCTAssertFalse(model.hasResult)
        }
    }

    @MainActor
    func testMalformedExplicitSessionsAndURLsCannotFallBackToLatest() async {
        let token = SessionToken()
        let stored = settings(token)
        XCTAssertTrue(DarwinBridge.writeDictationSettings(stored))
        let inputs: [(URL?, String?)] = [
            (nil, ""), (nil, "invalid"),
            (URL(string: "https://example.com/?session=\(token.rawValue)"), nil),
            (URL(string: "votype://dictation?session=invalid"), nil),
            (DictationConstants.buildDictationURL(session: token.rawValue), "invalid")
        ]
        for (url, explicit) in inputs {
            let runner = makeRunner([])
            let model = DictationViewModel(engine: runner)
            model.loadSettings(from: url, expectedSession: explicit)
            XCTAssertFalse(model.hasValidSettings)
            await model.startRecording()
            let requests = await runner.requests
            XCTAssertTrue(requests.isEmpty)
            XCTAssertEqual(DarwinBridge.peekDictationSettings(expectedSession: token.rawValue), stored)
            model.cleanup()
        }
    }

    @MainActor
    func testCancelledSettingsNeverStartEngine() async {
        let runner = makeRunner([])
        let model = DictationViewModel(engine: runner)
        let token = SessionToken()
        XCTAssertTrue(DarwinBridge.writeDictationSettings(settings(token)))
        XCTAssertTrue(DarwinBridge.cancelSession(token.rawValue))
        model.loadSettings(from: nil, expectedSession: token.rawValue)
        await model.startRecording()
        XCTAssertFalse(model.hasValidSettings)
        let requests = await runner.requests
        XCTAssertTrue(requests.isEmpty)
        model.cleanup()
    }

    @MainActor
    func testRepeatedAppearanceAndStartWhileActivePreserveSingleAdmissionAndLoadedToken() async throws {
        let runner = makeRunner([.authorizing, .listening(partial: "current")])
        let model = DictationViewModel(engine: runner)
        let token = SessionToken()
        load(model, token: token)
        let task = begin(model)
        defer { task.cancel(); model.cleanup() }
        try await waitUntil("foreground listening") { model.isRecording }
        model.loadSettings(from: nil, expectedSession: token.rawValue)
        let other = SessionToken()
        XCTAssertTrue(DarwinBridge.writeDictationSettings(settings(other)))
        model.loadSettings(from: nil)
        try await runBoundedOperation("repeated start returns") { await model.startRecording() }
        await model.stopRecording()
        await model.stopRecording()
        await model.cancelRecording()
        await model.cancelRecording()
        let requests = await runner.requests
        let stops = await runner.stoppedTokens
        let cancels = await runner.cancelledTokens
        XCTAssertEqual(requests.map(\.token), [token])
        XCTAssertEqual(stops, [token])
        XCTAssertEqual(cancels, [token])
        XCTAssertNotNil(DarwinBridge.peekDictationSettings(expectedSession: other.rawValue))
        await runner.finishAllStreams()
        try await runBoundedOperation("consumer returns") { await task.value }
    }

    @MainActor
    func testCleanupDuringGatedStartDetachesImmediatelyAndDefersOneEffectiveCancel() async throws {
        let runner = makeRunner([.authorizing, .listening(partial: "stale")])
        let scheduler = ManualDeadlineScheduler()
        let model = DictationViewModel(engine: runner, scheduler: scheduler, deadlines: .production)
        let token = SessionToken()
        load(model, token: token)
        let deadline = try XCTUnwrap(scheduler.pending.first)
        runner.startGates.enable(.commit, token: token)
        let task = begin(model)
        defer { runner.startGates.releaseAll(); task.cancel(); model.cleanup() }
        try await waitUntil("start suspended before admission") { await runner.requests.count == 1 }
        model.cleanup()
        model.cleanup()
        XCTAssertFalse(model.isRecording)
        XCTAssertFalse(model.hasValidSettings)
        let detachedText = model.liveText
        let detachedStatus = model.statusMessage
        deadline.action()
        try await requireStableCondition("no ineffective early cancel") { await runner.cancelledTokens.isEmpty }
        runner.startGates.releaseAll()
        try await waitUntil("one effective delayed cancellation") { await runner.cancelledTokens == [token] }
        try await runBoundedOperation("detached start returns") { await task.value }
        let owner = await runner.owner
        XCTAssertNil(owner)
        XCTAssertEqual(model.liveText, detachedText)
        XCTAssertEqual(model.statusMessage, detachedStatus)
        XCTAssertNil(model.permissionError)
        XCTAssertFalse(model.hasResult)
        try await requireStableCondition("cancellation stays unique") { await runner.cancelledTokens == [token] }
    }

    @MainActor
    func testSuccessorSurvivesCleanupDuringGatedStartAndOwnsEngineAfterPredecessorReturns() async throws {
        let runner = makeRunner([.authorizing, .listening(partial: "ready")])
        let model = DictationViewModel(engine: runner)
        let a = SessionToken()
        load(model, token: a)
        runner.startGates.enable(.commit, token: a)
        let first = begin(model)
        defer { runner.startGates.releaseAll(); first.cancel(); model.cleanup() }
        try await waitUntil("A start waiting before admission") { await runner.requests.map(\.token) == [a] }

        model.cleanup()
        let b = SessionToken()
        load(model, token: b)
        let successor = begin(model)
        defer { successor.cancel() }
        try await waitUntil("B synchronously claims before waiting for previous admission") {
            DarwinBridge.peekDictationSettings(expectedSession: b.rawValue) == nil
        }
        try await requireStableCondition("B cannot enter engine before delayed A returns") {
            await runner.requests.map(\.token) == [a]
        }
        runner.startGates.releaseAll()
        try await waitUntil("B admitted after A") { await runner.admittedTokens == [a, b] }
        try await waitUntil("B owns current presentation") { model.sessionId == b.rawValue && model.isRecording }
        try await runBoundedOperation("detached A returns") { await first.value }
        await runner.send(.listening(partial: "B current"), token: b)
        try await waitUntil("B text visible") { model.liveText == "B current" }

        first.cancel()
        await runner.send(.listening(partial: "late A"), token: a)
        await runner.send(.completed(plan), token: a)
        await runner.finish(token: a)
        try await requireStableCondition("late A cannot overwrite or cancel B") {
            let owner = await runner.owner
            let cancels = await runner.cancelledTokens
            return owner == b && cancels == [a] && model.liveText == "B current" && !model.hasResult
        }
        await model.stopRecording()
        let stops = await runner.stoppedTokens
        let pendingAtEntry = await runner.settingsPresentAtStart
        let cancellationsAtEntry = await runner.cancellationsAtStart
        XCTAssertEqual(stops, [b])
        XCTAssertEqual(pendingAtEntry, [false, false])
        XCTAssertEqual(cancellationsAtEntry, [[], [a]], "A cancellation must finish before B engine entry")
        await runner.send(.completed(plan), token: b)
        try await runBoundedOperation("B terminal ends consumer") { await successor.value }
        XCTAssertTrue(model.hasResult)
        XCTAssertEqual(model.statusMessage, "识别完成 ✓")
        await model.cancelRecording()
        let cancels = await runner.cancelledTokens
        XCTAssertEqual(cancels, [a], "Terminal cleanup must not cancel the completed successor")
    }

    @MainActor
    func testClaimedQueuedSuccessorStillAdmitsAndCancelsOnceAfterCleanupOrCancel() async throws {
        for explicitCancel in [false, true] {
            let runner = makeRunner([.authorizing, .listening(partial: "must remain detached")])
            let model = DictationViewModel(engine: runner)
            let a = SessionToken()
            load(model, token: a)
            runner.startGates.enable(.commit, token: a)
            let first = begin(model)
            defer { runner.startGates.releaseAll(); first.cancel(); model.cleanup() }
            try await waitUntil("A suspended before admission") { await runner.requests.map(\.token) == [a] }
            model.cleanup()
            let b = SessionToken()
            load(model, token: b)
            let successor = begin(model)
            defer { successor.cancel() }
            try await waitUntil("B claimed while queued") {
                DarwinBridge.peekDictationSettings(expectedSession: b.rawValue) == nil
            }
            if explicitCancel {
                await model.cancelRecording()
            } else {
                model.cleanup()
            }
            XCTAssertFalse(model.hasValidSettings)
            XCTAssertFalse(model.isRecording)
            let detachedText = model.liveText
            let detachedStatus = model.statusMessage
            await model.stopRecording()
            await model.cancelRecording()
            model.cleanup()
            try await requireStableCondition("queued successor cannot cancel before its admission") {
                await runner.cancelledTokens.isEmpty
            }
            successor.cancel()
            runner.startGates.releaseAll()
            try await waitUntil("both claimed requests admitted and cancelled") {
                let admissions = await runner.admittedTokens
                let cancels = await runner.cancelledTokens
                return admissions == [a, b] && cancels == [a, b]
            }
            try await runBoundedOperation("detached predecessor returns") { await first.value }
            try await runBoundedOperation("detached claimed successor returns") { await successor.value }
            let owner = await runner.owner
            let cancellationsAtEntry = await runner.cancellationsAtStart
            let pendingAtEntry = await runner.settingsPresentAtStart
            XCTAssertNil(owner)
            XCTAssertEqual(cancellationsAtEntry, [[], [a]])
            XCTAssertEqual(pendingAtEntry, [false, false])
            await runner.send(.listening(partial: "late B"), token: b)
            await runner.send(.completed(plan), token: b)
            await runner.finish(token: a)
            await runner.finish(token: b)
            await model.stopRecording()
            await model.cancelRecording()
            model.cleanup()
            try await requireStableCondition("detached B cannot revive UI or issue duplicate commands") {
                let cancels = await runner.cancelledTokens
                let stops = await runner.stoppedTokens
                let currentOwner = await runner.owner
                return cancels == [a, b] && stops.isEmpty && currentOwner == nil
                    && model.liveText == detachedText && model.statusMessage == detachedStatus
                    && !model.isRecording && !model.hasResult
            }
        }
    }

    @MainActor
    func testWrongMatchingHandshakeAndNonterminalEOFFailClosed() async throws {
        let streams: [[DictationSessionEvent]] = [[.listening(partial: "invalid")], [.authorizing, .listening(partial: "unfinished")], []]
        for events in streams {
            let runner = makeRunner(events, finishes: true)
            let model = DictationViewModel(engine: runner)
            let token = SessionToken()
            load(model, token: token)
            try await runBoundedOperation("invalid stream ends") { await model.startRecording() }
            try await waitUntil("matching attempt cancelled") { await runner.cancelledTokens == [token] }
            XCTAssertNotNil(model.permissionError)
            XCTAssertTrue(model.canExit)
            XCTAssertFalse(model.isRecording)
            XCTAssertFalse(model.hasResult)
            model.cleanup()
        }
    }

    @MainActor
    func testForeignAndOutOfOrderEventsCannotCorruptMatchingHandshakeOrPresentation() async throws {
        let runner = makeRunner([])
        let model = DictationViewModel(engine: runner)
        let token = SessionToken()
        load(model, token: token)
        let task = begin(model)
        defer { task.cancel(); model.cleanup() }
        try await waitUntil("stream installed") { await runner.admittedTokens == [token] }
        await runner.send(.failed(.startTimeout), token: token, envelopeToken: SessionToken(), sequence: 100)
        await runner.send(.authorizing, token: token, sequence: 1)
        await runner.send(.listening(partial: "current"), token: token, sequence: 3)
        try await waitUntil("valid handshake accepted") { model.liveText == "current" }
        await runner.send(.listening(partial: "stale"), token: token, sequence: 2)
        await runner.send(.failed(.recognition), token: token, sequence: 3)
        try await requireStableCondition("older events ignored") { model.liveText == "current" && model.permissionError == nil }
        await runner.send(.completed(plan), token: token, sequence: 4)
        try await waitUntil("matching completion") { model.hasResult }
    }

    @MainActor
    func testTerminalClearsRequestAndLateEventsCommandsOrAppearanceCannotRestartIt() async throws {
        let terminals: [DictationSessionEvent] = [.completed(plan), .failed(.permissionDenied(.microphone)), .cancelled]
        for terminal in terminals {
            let runner = makeRunner([.authorizing, .listening(partial: "done"), terminal])
            let model = DictationViewModel(engine: runner)
            let token = SessionToken()
            load(model, token: token)
            let task = begin(model)
            defer { task.cancel(); model.cleanup() }
            try await runBoundedOperation("terminal ends consumer without waiting for EOF") { await task.value }
            let status = model.statusMessage
            if case .cancelled = terminal {
                XCTAssertNil(model.permissionError)
                XCTAssertFalse(model.hasResult)
            }
            if case .failed(let failure) = terminal { XCTAssertEqual(model.permissionError, failure.userMessage) }
            await model.stopRecording()
            await model.cancelRecording()
            model.loadSettings(from: nil, expectedSession: token.rawValue)
            try await runBoundedOperation("terminal cannot restart") { await model.startRecording() }
            await runner.send(.listening(partial: "late"), token: token)
            await runner.finish(token: token)
            try await runBoundedOperation("terminal consumer returns") { await task.value }
            let requests = await runner.requests
            let stops = await runner.stoppedTokens
            let cancels = await runner.cancelledTokens
            XCTAssertEqual(requests.count, 1)
            XCTAssertTrue(stops.isEmpty)
            XCTAssertTrue(cancels.isEmpty)
            XCTAssertEqual(model.statusMessage, status)
            XCTAssertNotEqual(model.liveText, "late")
        }
    }

    @MainActor
    func testCleanupBeforeClaimLeavesRequestRecoverableAndOldDeadlineCannotExpireNewLoad() async throws {
        let runner = makeRunner([])
        let scheduler = ManualDeadlineScheduler()
        let model = DictationViewModel(engine: runner, scheduler: scheduler, deadlines: .production)
        defer { model.cleanup() }
        let oldToken = SessionToken()
        load(model, token: oldToken)
        let oldDeadline = try XCTUnwrap(scheduler.pending.first)
        model.cleanup()
        XCTAssertNotNil(DarwinBridge.peekDictationSettings(expectedSession: oldToken.rawValue))
        XCTAssertTrue(oldDeadline.task.isCancelled)
        let newToken = SessionToken()
        load(model, token: newToken)
        oldDeadline.action()
        try await requireStableCondition("old deadline cannot expire new pending request") {
            model.hasValidSettings && model.sessionId == newToken.rawValue && model.permissionError == nil
        }
        let requests = await runner.requests
        let cancels = await runner.cancelledTokens
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(cancels.isEmpty)
    }

    @MainActor
    func testPreClaimCleanupAndSameSessionReloadRejectsOldDeadlineButHonorsNewDeadline() async throws {
        let runner = makeRunner([])
        let scheduler = ManualDeadlineScheduler()
        let model = DictationViewModel(engine: runner, scheduler: scheduler, deadlines: .production)
        defer { model.cleanup() }
        let token = SessionToken()
        let stored = settings(token)
        XCTAssertTrue(DarwinBridge.writeDictationSettings(stored))
        model.loadSettings(from: nil, expectedSession: token.rawValue)
        let oldDeadline = try XCTUnwrap(scheduler.pending.first)
        model.cleanup()
        XCTAssertEqual(DarwinBridge.peekDictationSettings(expectedSession: token.rawValue), stored)
        XCTAssertTrue(oldDeadline.task.isCancelled)

        model.loadSettings(from: nil, expectedSession: token.rawValue)
        let newDeadline = try XCTUnwrap(scheduler.pending.last)
        XCTAssertFalse(newDeadline.task.isCancelled)
        XCTAssertFalse(oldDeadline.task === newDeadline.task)
        oldDeadline.action()
        try await requireStableCondition("old callback cannot expire a new presentation of the same UUID") {
            model.hasValidSettings && model.sessionId == token.rawValue && model.permissionError == nil
        }
        XCTAssertEqual(DarwinBridge.peekDictationSettings(expectedSession: token.rawValue), stored)

        newDeadline.action()
        try await waitUntil("new same-session claim deadline remains effective") { model.permissionError != nil }
        XCTAssertFalse(model.hasValidSettings)
        XCTAssertEqual(model.permissionError, "未能启动该语音请求，请返回键盘重试")
        XCTAssertTrue(model.canExit)
        await model.startRecording()
        let requests = await runner.requests
        let cancels = await runner.cancelledTokens
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(cancels.isEmpty)
        XCTAssertEqual(DarwinBridge.peekDictationSettings(expectedSession: token.rawValue), stored)
    }

    @MainActor
    func testPreparationAndProcessingDoNotClaimRecordingVisuals() async throws {
        let runner = makeRunner([.authorizing, .preparing])
        let model = DictationViewModel(engine: runner)
        let token = SessionToken()
        load(model, token: token)
        let task = begin(model)
        defer { task.cancel(); model.cleanup() }
        try await waitUntil("admitted preparation") { await runner.admittedTokens == [token] }
        try await requireStableCondition("preparation is not recording") { !model.isRecording && !model.hasResult }
        await runner.send(.listening(partial: "partial"), token: token)
        try await waitUntil("recording visuals") { model.isRecording && model.liveText == "partial" }
        await runner.send(.processing, token: token)
        try await waitUntil("processing stops recording visuals") { !model.isRecording }
        XCTAssertEqual(model.liveText, "partial")
        XCTAssertFalse(model.hasResult)
        XCTAssertNil(model.permissionError)
    }

    @MainActor
    func testDefaultForegroundAndBackgroundUseSameEnvironmentActor() {
        let model = DictationViewModel()
        XCTAssertEqual(model.engineIdentity, ObjectIdentifier(DictationSessionEnvironment.shared.engine))
        XCTAssertEqual(model.engineIdentity, BackgroundDictationManager.shared.engineIdentity)
        model.cleanup()
    }
}
