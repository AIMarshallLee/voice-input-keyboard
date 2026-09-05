import XCTest
@testable import VoiceInputApp

final class DictationSessionEngineTests: XCTestCase {
    func testHappyPathEmitsOrderedEventsAndCommitsBeforeCompleted() async throws {
        let harness = EngineHarness()
        let request = harness.makeRequest()
        harness.outputGates.enable(.commit, token: request.token)
        defer { harness.releaseAllTestWaiters() }

        let events = try await harness.start(request)
        defer { events.cancel() }
        try await harness.waitForEvent(.listening(partial: ""), in: events)

        harness.speech.send(
            .success(.init(transcript: "你好", isFinal: false)),
            index: 0
        )
        try await harness.waitForEvent(.listening(partial: "你好"), in: events)

        harness.speech.send(
            .success(.init(transcript: "你好世界", isFinal: true)),
            index: 0
        )
        try await waitUntil("terminal output commit entry") {
            await harness.output.commitCount(for: request.token) == 1
        }
        XCTAssertFalse(events.events.contains { $0.event.isTerminal })
        XCTAssertFalse(events.isFinished)

        harness.outputGates.release(.commit, token: request.token)
        try await harness.waitForFinished(events)

        let received = events.events
        XCTAssertEqual(received.map(\.sequence), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(received.map(\.event), [
            .authorizing,
            .preparing,
            .listening(partial: ""),
            .listening(partial: "你好"),
            .processing,
            .completed(harness.completedPlan)
        ])
        let terminals = await harness.output.terminals
        XCTAssertEqual(terminals.count, 1)
        XCTAssertEqual(terminals.first?.0, .completed(harness.completedPlan))
        XCTAssertEqual(terminals.first?.1, request.token)
    }

    func testStopWhileListeningEndsAudioAndWaitsForFinalRecognition() async throws {
        let harness = EngineHarness()
        defer { harness.releaseAllTestWaiters() }
        let request = harness.makeRequest()
        let events = try await harness.start(request)
        defer { events.cancel() }
        try await harness.waitForEvent(.listening(partial: ""), in: events)

        try await runBoundedOperation("stop while listening") {
            await harness.engine.stop(token: request.token)
        }
        try await harness.waitForEvent(.processing, in: events)

        XCTAssertEqual(harness.audio.session(at: 0).stopCount, 1)
        XCTAssertEqual(harness.speech.session(at: 0).endAudioCount, 1)
        let commitCountBeforeFinal = await harness.output.commitCount(for: request.token)
        XCTAssertEqual(commitCountBeforeFinal, 0)
        XCTAssertFalse(events.isFinished)

        harness.speech.send(
            .success(.init(transcript: "最终文本", isFinal: true)),
            index: 0
        )
        try await harness.waitForFinished(events)
        XCTAssertEqual(events.events.last?.event, .completed(harness.completedPlan))
    }

    func testStopWhileAuthorizingCancelsAndLatePermissionDoesNotCreateResources() async throws {
        let harness = EngineHarness(permissionSuspended: true)
        defer { harness.releaseAllTestWaiters() }
        let request = harness.makeRequest()
        let events = try await harness.start(request)
        defer { events.cancel() }
        try await waitUntil("permission request entry") {
            harness.permissions.policies.count == 1
        }

        try await runBoundedOperation("stop while authorizing") {
            await harness.engine.stop(token: request.token)
        }
        try await harness.waitForFinished(events)
        XCTAssertEqual(events.events.last?.event, .cancelled)
        let commitCount = await harness.output.commitCount(for: request.token)
        XCTAssertEqual(commitCount, 1)

        harness.permissions.resume(with: .success(()))
        try await requireStableCondition("cancelled authorization stays resource-free") {
            harness.speech.sessionCount == 0 && harness.audio.sessionCount == 0
        }
    }

    func testRepeatedStopWhileProcessingIsNoOp() async throws {
        let harness = EngineHarness()
        defer { harness.releaseAllTestWaiters() }
        let request = harness.makeRequest()
        let events = try await harness.start(request)
        defer { events.cancel() }
        try await harness.waitForEvent(.listening(partial: ""), in: events)

        try await runBoundedOperation("first stop enters processing") {
            await harness.engine.stop(token: request.token)
        }
        try await harness.waitForEvent(.processing, in: events)
        let captureStopCount = harness.audio.session(at: 0).stopCount
        let endAudioCount = harness.speech.session(at: 0).endAudioCount

        try await runBoundedOperation("second stop is ignored during processing") {
            await harness.engine.stop(token: request.token)
        }
        XCTAssertEqual(harness.audio.session(at: 0).stopCount, captureStopCount)
        XCTAssertEqual(harness.speech.session(at: 0).endAudioCount, endAudioCount)
        let commitCountBeforeFinal = await harness.output.commitCount(for: request.token)
        XCTAssertEqual(commitCountBeforeFinal, 0)
        XCTAssertEqual(events.events.filter { $0.event == .processing }.count, 1)

        harness.speech.send(
            .success(.init(transcript: "最终文本", isFinal: true)),
            index: 0
        )
        try await harness.waitForFinished(events)
        XCTAssertEqual(events.events.last?.event, .completed(harness.completedPlan))
    }

    func testCancelDiscardsPartialAndCommitsCancelledOnce() async throws {
        let harness = EngineHarness()
        defer { harness.releaseAllTestWaiters() }
        let request = harness.makeRequest()
        let events = try await harness.start(request)
        defer { events.cancel() }
        try await harness.waitForEvent(.listening(partial: ""), in: events)

        harness.speech.send(
            .success(.init(transcript: "不会提交", isFinal: false)),
            index: 0
        )
        try await harness.waitForEvent(.listening(partial: "不会提交"), in: events)
        try await runBoundedOperation("first cancel") {
            await harness.engine.cancel(token: request.token)
        }
        try await runBoundedOperation("duplicate cancel") {
            await harness.engine.cancel(token: request.token)
        }
        try await harness.waitForFinished(events)

        let allTerminals = await harness.output.terminals
        let terminals = allTerminals.filter { $0.1 == request.token }
        let processingCallCount = await harness.processor.calls.count
        XCTAssertEqual(events.events.last?.event, .cancelled)
        XCTAssertEqual(events.events.filter { $0.event.isTerminal }.count, 1)
        XCTAssertEqual(terminals.map(\.0), [.cancelled])
        XCTAssertEqual(harness.speech.session(at: 0).cancelCount, 1)
        XCTAssertEqual(harness.speech.session(at: 0).endAudioCount, 0)
        XCTAssertEqual(processingCallCount, 0)
    }

    func testAudioSystemEventsFinishTheListeningSessionWithMatchingFailure() async throws {
        let cases: [(DictationAudioSystemEvent, DictationFailure)] = [
            (.interruptionBegan, .interrupted),
            (.inputRouteLost, .inputRouteLost),
            (.mediaServicesReset, .mediaServicesReset)
        ]

        for (systemEvent, expectedFailure) in cases {
            let harness = EngineHarness()
            let request = harness.makeRequest()
            let events = try await harness.start(request)
            try await harness.waitForEvent(.listening(partial: ""), in: events)

            try await runBoundedOperation("audio system event \(systemEvent)") {
                await harness.engine.handleAudioSystemEvent(systemEvent)
            }
            try await harness.waitForFinished(events)

            XCTAssertEqual(events.events.last?.event, .failed(expectedFailure))
            let allTerminals = await harness.output.terminals
            let terminals = allTerminals.filter { $0.1 == request.token }
            XCTAssertEqual(terminals.map(\.0), [.failed(expectedFailure)])
            XCTAssertEqual(harness.speech.session(at: 0).cancelCount, 1)
            events.cancel()
            harness.releaseAllTestWaiters()
        }
    }

    func testThreeStartsKeepLatestOwnerWhileOlderCommitsAreSuspended() async throws {
        let harness = EngineHarness()
        defer { harness.releaseAllTestWaiters() }
        let first = harness.makeRequest()
        let second = harness.makeRequest()
        let third = harness.makeRequest()
        harness.outputGates.enable(.commit, token: first.token)
        harness.outputGates.enable(.commit, token: second.token)

        let firstEvents = try await harness.start(first)
        defer { firstEvents.cancel() }
        try await harness.waitForEvent(.listening(partial: ""), in: firstEvents)

        let secondEvents = try await harness.start(second)
        defer { secondEvents.cancel() }
        try await waitUntil("first suspended terminal commit") {
            await harness.output.commitCount(for: first.token) == 1
        }
        try await harness.waitForEvent(.listening(partial: ""), in: secondEvents)

        let thirdEvents = try await harness.start(third)
        defer { thirdEvents.cancel() }
        try await waitUntil("second suspended terminal commit") {
            await harness.output.commitCount(for: second.token) == 1
        }
        try await harness.waitForEvent(.listening(partial: ""), in: thirdEvents)
        XCTAssertFalse(firstEvents.isFinished)
        XCTAssertFalse(secondEvents.isFinished)

        harness.speech.send(
            .success(.init(transcript: "第三个会话", isFinal: true)),
            index: 2
        )
        try await harness.waitForFinished(thirdEvents)
        XCTAssertEqual(thirdEvents.events.last?.event, .completed(harness.completedPlan))

        harness.outputGates.release(.commit, token: second.token)
        try await harness.waitForFinished(secondEvents)
        harness.outputGates.release(.commit, token: first.token)
        try await harness.waitForFinished(firstEvents)

        XCTAssertEqual(firstEvents.events.filter { $0.event.isTerminal }.map(\.event), [.cancelled])
        XCTAssertEqual(secondEvents.events.filter { $0.event.isTerminal }.map(\.event), [.cancelled])
        XCTAssertEqual(thirdEvents.events.filter { $0.event.isTerminal }.map(\.event), [
            .completed(harness.completedPlan)
        ])
        let firstCommitCount = await harness.output.commitCount(for: first.token)
        let secondCommitCount = await harness.output.commitCount(for: second.token)
        let thirdCommitCount = await harness.output.commitCount(for: third.token)
        let allTerminals = await harness.output.terminals
        XCTAssertEqual(firstCommitCount, 1)
        XCTAssertEqual(secondCommitCount, 1)
        XCTAssertEqual(thirdCommitCount, 1)
        XCTAssertEqual(allTerminals.filter { $0.1 == first.token }.map(\.0), [.cancelled])
        XCTAssertEqual(allTerminals.filter { $0.1 == second.token }.map(\.0), [.cancelled])
        XCTAssertEqual(allTerminals.filter { $0.1 == third.token }.map(\.0), [
            .completed(harness.completedPlan)
        ])
    }

    func testSupersessionDuringAuthorizingPublicationSkipsOldPermissionWork() async throws {
        let harness = EngineHarness()
        defer { harness.releaseAllTestWaiters() }
        let first = harness.makeRequest()
        let second = harness.makeRequest()
        harness.outputGates.enable(.publishLive, token: first.token)

        let pendingFirst = harness.beginStart(first)
        defer { pendingFirst.cancel() }
        try await waitUntil("first authorizing publication entry") {
            let liveEvents = await harness.output.liveEvents
            return liveEvents.contains {
                $0.token == first.token && $0.event == .authorizing
            }
        }

        let secondEvents = try await harness.start(second)
        defer { secondEvents.cancel() }
        try await harness.waitForEvent(.listening(partial: ""), in: secondEvents)
        XCTAssertEqual(harness.permissions.policies.count, 1)
        XCTAssertEqual(harness.speech.sessionCount, 1)
        XCTAssertEqual(harness.audio.sessionCount, 1)

        harness.outputGates.release(.publishLive, token: first.token)
        let firstEvents = try await pendingFirst.waitForRecorder()
        defer { firstEvents.cancel() }
        try await harness.waitForFinished(firstEvents)
        try await requireStableCondition("old permission kickoff remains skipped") {
            harness.permissions.policies.count == 1
                && harness.speech.sessionCount == 1
                && harness.audio.sessionCount == 1
        }

        XCTAssertEqual(firstEvents.events.filter { $0.event.isTerminal }.map(\.event), [.cancelled])
        let terminalsAfterFirstResumed = await harness.output.terminals
        XCTAssertEqual(
            terminalsAfterFirstResumed.filter { $0.1 == first.token }.map(\.0),
            [.cancelled]
        )
        harness.speech.send(
            .success(.init(transcript: "仍由第二个会话完成", isFinal: true)),
            index: 0
        )
        try await harness.waitForFinished(secondEvents)
        XCTAssertEqual(secondEvents.events.last?.event, .completed(harness.completedPlan))
        let firstCommitCount = await harness.output.commitCount(for: first.token)
        let secondCommitCount = await harness.output.commitCount(for: second.token)
        XCTAssertEqual(firstCommitCount, 1)
        XCTAssertEqual(secondCommitCount, 1)
    }

    func testSupersessionClosesOldResourcesBeforeNewCaptureStarts() async throws {
        let harness = EngineHarness()
        defer { harness.releaseAllTestWaiters() }
        let first = harness.makeRequest()
        let second = harness.makeRequest()

        let firstEvents = try await harness.start(first)
        defer { firstEvents.cancel() }
        try await harness.waitForEvent(.listening(partial: ""), in: firstEvents)
        try await harness.waitForAudioCaptureSessionCount(1)

        let secondEvents = try await harness.start(second)
        defer { secondEvents.cancel() }
        try await harness.waitForEvent(.listening(partial: ""), in: secondEvents)
        try await harness.waitForFinished(firstEvents)

        let journal = harness.journal.entries
        let oldCaptureStopped = try XCTUnwrap(journal.firstIndex(of: "capture.0.stop"))
        let oldSpeechCancelled = try XCTUnwrap(journal.firstIndex(of: "speech.0.cancel"))
        let oldAudioDeactivated = try XCTUnwrap(journal.firstIndex(of: "audio.deactivate"))
        let newCaptureStarted = try XCTUnwrap(journal.firstIndex(of: "capture.1.start"))
        XCTAssertLessThan(oldCaptureStopped, newCaptureStarted)
        XCTAssertLessThan(oldSpeechCancelled, newCaptureStarted)
        XCTAssertLessThan(oldAudioDeactivated, newCaptureStarted)
        XCTAssertEqual(harness.speech.session(at: 0).cancelCount, 1)

        harness.outputGates.enable(.publishLive, token: second.token)
        harness.speech.send(
            .success(.init(transcript: "旧会话迟到片段", isFinal: false)),
            index: 0
        )
        harness.speech.send(
            .success(.init(transcript: "旧会话迟到终态", isFinal: true)),
            index: 0
        )
        harness.speech.send(
            .failure(.recognition),
            index: 0
        )
        harness.speech.send(
            .success(.init(transcript: "第二个会话仍在监听", isFinal: false)),
            index: 1
        )
        try await waitUntil("new session callback reaches gated live output") {
            let liveEvents = await harness.output.liveEvents
            return liveEvents.contains {
                $0.token == second.token
                    && $0.event == .listening(partial: "第二个会话仍在监听")
            }
        }
        try await harness.waitForEvent(
            .listening(partial: "第二个会话仍在监听"),
            in: secondEvents
        )
        harness.outputGates.release(.publishLive, token: second.token)

        let expectedSecondEvents: [DictationSessionEvent] = [
            .authorizing,
            .preparing,
            .listening(partial: ""),
            .listening(partial: "第二个会话仍在监听")
        ]
        try await requireStableCondition("late callbacks leave the new owner unchanged") {
            let allLiveEvents = await harness.output.liveEvents
            let liveEvents = allLiveEvents.filter {
                $0.token == second.token
            }.map(\.event)
            let firstCommitCount = await harness.output.commitCount(for: first.token)
            let commitCount = await harness.output.commitCount(for: second.token)
            return secondEvents.events.map(\.event) == expectedSecondEvents
                && liveEvents == expectedSecondEvents
                && firstCommitCount == 1
                && commitCount == 0
                && harness.speech.session(at: 0).cancelCount == 1
        }

        harness.speech.send(
            .success(.init(transcript: "第二个会话最终文本", isFinal: true)),
            index: 1
        )
        try await harness.waitForFinished(secondEvents)
        XCTAssertEqual(secondEvents.events.last?.event, .completed(harness.completedPlan))
        let firstCommitCount = await harness.output.commitCount(for: first.token)
        let secondCommitCount = await harness.output.commitCount(for: second.token)
        XCTAssertEqual(firstCommitCount, 1)
        XCTAssertEqual(secondCommitCount, 1)
    }
}

private extension DictationSessionEvent {
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .authorizing, .preparing, .listening, .processing:
            return false
        }
    }
}
