import XCTest
@testable import TapitoVoiceCore

@MainActor final class VoiceSessionTests: XCTestCase {
    func testSpokenTurnsKeepConversationAndReturnToListeningAfterPlayback() async throws {
        let (session, audio, runner) = fixture()
        try await session.start(initialTask: "打开备忘录")
        let first = try XCTUnwrap(runner.turns.first)
        runner.finish(first.run, .success(.init(response: "备忘录已打开")))
        await settle { session.state.phase == .speaking }
        XCTAssertEqual(audio.spoken, ["备忘录已打开"])
        audio.emit(.playbackFinished(try XCTUnwrap(audio.playback)))
        await settle { session.state.phase == .listening }
        audio.emit(.utterance("新建采购清单"))
        XCTAssertEqual(runner.turns.map(\.conversation), [first.conversation, first.conversation])
        session.end(); runner.finish(runner.turns[1].run, .success(.init(response: "已停止")))
    }

    func testEndIgnoresLateAudioAndModelResults() async throws {
        let (session, audio, runner) = fixture()
        try await session.start(initialTask: "查询")
        let callback = audio.events
        session.end()
        callback?(.utterance("不能执行"))
        runner.finish(runner.turns[0].run, .success(.init(response: "不能播报")))
        await settle { runner.waiters.isEmpty }
        XCTAssertEqual(session.state.phase, .ended)
        XCTAssertEqual(runner.turns.count, 1)
        XCTAssertTrue(audio.spoken.isEmpty)
    }

    func testPauseResumeDropsOldCaptureCallbacksAndDoesNotRestartTask() async throws {
        let (session, audio, runner) = fixture()
        try await session.start(initialTask: "原任务")
        let stale = audio.events
        session.pause()
        runner.finish(runner.turns[0].run, .success(.init(response: "停止")))
        await settle { session.state.phase == .paused }
        try await session.resume()
        stale?(.utterance("旧录音"))
        XCTAssertEqual(session.state.phase, .listening)
        XCTAssertEqual(runner.turns.count, 1)
        session.end()
        try await session.start(initialTask: "新会话")
        runner.finish(runner.turns[1].run, .success(.init(response: "新答复")))
        await settle { session.state.phase == .speaking }
        session.end()
    }

    func testPermissionFailureCreatesNoConversationOrRun() async {
        let (session, audio, runner) = fixture()
        audio.startError = TestFailure.permission
        do { try await session.start(initialTask: "不能发送"); XCTFail("Expected permission failure") } catch {}
        XCTAssertEqual(session.state.phase, .failed)
        XCTAssertEqual(runner.conversations, 0)
        XCTAssertTrue(runner.turns.isEmpty)
    }

    func testRequiredPresentationIsReadyBeforeMicrophoneStarts() async throws {
        let (session, audio, runner) = fixture()
        session.prepareCapture = {
            XCTAssertEqual(audio.starts, 0)
            XCTAssertEqual(runner.conversations, 1)
            XCTAssertNotNil(session.state.sessionID)
            XCTAssertNotNil(session.state.conversationID)
            XCTAssertEqual(session.state.phase, .preparing)
        }
        try await session.start()
        XCTAssertEqual(audio.starts, 1)
        XCTAssertEqual(session.state.phase, .listening)
        session.end()
    }

    func testActivityFailureNeverStartsMicrophoneOrTask() async {
        let (session, audio, runner) = fixture()
        session.prepareCapture = { throw TestFailure.presentation }
        do { try await session.start(initialTask: "不得发送"); XCTFail("Expected presentation failure") } catch {}
        XCTAssertEqual(audio.starts, 0)
        XCTAssertTrue(runner.turns.isEmpty)
        XCTAssertEqual(session.state.phase, .failed)
    }

    func testFailureDuringPresentationPreparationIsReturnedToCaller() async {
        let (session, audio, _) = fixture()
        session.prepareCapture = { session.fail("设备已锁定") }
        do { try await session.start(); XCTFail("Must not report failed preparation as success") }
        catch { XCTAssertEqual(error.localizedDescription, "设备已锁定") }
        XCTAssertEqual(audio.starts, 0)
        XCTAssertEqual(session.state.phase, .failed)
    }

    func testEndWhileActivityStartsPreventsCaptureAndNewStartupOverlap() async throws {
        let (session, audio, runner) = fixture()
        var pending: CheckedContinuation<Void, Never>?
        session.prepareCapture = { await withCheckedContinuation { pending = $0 } }
        let start = Task { try await session.start(initialTask: "不得发送") }
        await settle { pending != nil }
        try session.end(sessionID: XCTUnwrap(session.state.sessionID))
        do { try await session.start(); XCTFail("Cannot overlap startup") } catch {}
        pending?.resume()
        try await start.value
        XCTAssertEqual(audio.starts, 0)
        XCTAssertTrue(runner.turns.isEmpty)
        XCTAssertEqual(session.state.phase, .ended)
    }

    func testStaleIslandCannotEndReplacementVoiceSession() async throws {
        let (session, audio, _) = fixture()
        try await session.start()
        let oldID = try XCTUnwrap(session.state.sessionID)
        try session.end(sessionID: oldID)
        try session.end(sessionID: oldID) // Repeated delivery is harmless for the same ended session.
        try await session.start()
        let stops = audio.stops
        XCTAssertThrowsError(try session.end(sessionID: oldID))
        XCTAssertEqual(audio.stops, stops)
        XCTAssertEqual(session.state.phase, .listening)
        session.end()
    }

    func testStartupAudioEventFailureIsReturnedToShortcutCaller() async {
        let (session, audio, runner) = fixture()
        audio.startEvent = .failure("麦克风启动失败")
        do { try await session.start(initialTask: "不能发送"); XCTFail("Must not report shortcut success") }
        catch { XCTAssertEqual(error.localizedDescription, "麦克风启动失败") }
        XCTAssertEqual(session.state.phase, .failed)
        XCTAssertTrue(runner.turns.isEmpty)
    }

    func testEndDuringPermissionPromptPreventsOverlappingStartup() async throws {
        let (session, audio, runner) = fixture()
        audio.holdStart = true
        let start = Task { try await session.start(initialTask: "不能发送") }
        await settle { audio.startContinuation != nil }
        session.end()
        do { try await session.start(); XCTFail("Cannot overlap permission acquisition") } catch {}
        audio.startContinuation?.resume(); audio.startContinuation = nil
        try await start.value
        XCTAssertEqual(session.state.phase, .ended)
        XCTAssertTrue(runner.turns.isEmpty)
    }

    func testBlockedTurnStopsRecordingInsteadOfClaimingSuccess() async throws {
        let (session, audio, runner) = fixture()
        try await session.start(initialTask: "操作")
        runner.finish(runner.turns[0].run, .success(.init(response: "动作结果未知", needsAttention: true)))
        await settle { session.state.phase == .failed }
        XCTAssertEqual(session.state.error, "动作结果未知")
        XCTAssertTrue(audio.spoken.isEmpty)
        XCTAssertGreaterThan(audio.stops, 0)
    }

    func testAudioReleasedBeforeDispatchAndRemainsOffForEntireRun() async throws {
        let (session, audio, runner) = fixture()
        var diagnostics: [String] = []
        session.onDiagnostic = { diagnostics.append($0) }
        runner.onStart = { XCTAssertEqual(audio.mode, "released") }
        try await session.start()
        let oldCapture = audio.events
        audio.emit(.utterance("原任务"))
        XCTAssertEqual(audio.mode, "released")
        XCTAssertEqual(session.state.phase, .executing)
        for text in ["无关对话", "暂停任务", "Tapito，替换任务", "结束对话"] {
            oldCapture?(.partial(text)); oldCapture?(.utterance(text))
        }
        XCTAssertTrue(runner.stops.isEmpty)
        XCTAssertEqual(runner.turns.count, 1)
        XCTAssertThrowsError(try session.submit("不能插队"))
        await Task.yield()
        XCTAssertEqual(audio.mode, "released")
        XCTAssertTrue(diagnostics.contains("voice.audioReleased reason=execution"))
        runner.finish(runner.turns[0].run, .success(.init(response: "完成")))
        await settle { session.state.phase == .speaking }
        XCTAssertEqual(audio.mode, "playback")
        XCTAssertEqual(audio.starts, 1, "Playback must not reopen the microphone")
        let oldPlayback = audio.events
        audio.emit(.playbackFinished(try XCTUnwrap(audio.playback)))
        await settle { session.state.phase == .listening }
        XCTAssertEqual(audio.mode, "capture")
        oldCapture?(.utterance("旧录音")); oldPlayback?(.utterance("播报残留"))
        XCTAssertEqual(runner.turns.count, 1)
        session.end()
    }

    func testAudioReleaseFailurePreventsDispatch() async throws {
        let (session, audio, runner) = fixture()
        try await session.start()
        audio.stopError = TestFailure.cleanup
        XCTAssertThrowsError(try session.submit("不得执行"))
        XCTAssertTrue(runner.turns.isEmpty)
        XCTAssertEqual(session.state.phase, .failed)
        XCTAssertNotNil(session.state.error)
    }

    func testPlaybackFailureDoesNotRestartMicrophoneOrReplayTask() async throws {
        let (session, audio, runner) = fixture()
        try await session.start(initialTask: "任务")
        audio.playbackError = TestFailure.cleanup
        runner.finish(runner.turns[0].run, .success(.init(response: "完成")))
        await settle { session.state.phase == .failed }
        XCTAssertEqual(audio.starts, 1)
        XCTAssertEqual(audio.mode, "released")
        XCTAssertEqual(runner.turns.count, 1)
    }

    func testEndDuringPlaybackPreparationCannotPlayOrRestartMicrophone() async throws {
        let (session, audio, runner) = fixture()
        try await session.start(initialTask: "任务")
        audio.holdPlayback = true
        runner.finish(runner.turns[0].run, .success(.init(response: "不能播报")))
        await settle { audio.playbackContinuation != nil }
        session.end()
        do { try await session.start(); XCTFail("Cannot overlap audio handoff") } catch {}
        audio.playbackContinuation?.resume(); audio.playbackContinuation = nil
        await settle { audio.mode == "released" }
        XCTAssertTrue(audio.spoken.isEmpty)
        XCTAssertEqual(audio.starts, 1)
        XCTAssertEqual(session.state.phase, .ended)
    }

    func testActivityIsRevalidatedBeforeListeningAgain() async throws {
        let (session, audio, runner) = fixture()
        try await session.start(initialTask: "任务")
        runner.finish(runner.turns[0].run, .success(.init(response: "完成")))
        await settle { session.state.phase == .speaking }
        session.prepareCapture = { throw TestFailure.presentation }
        audio.emit(.playbackFinished(try XCTUnwrap(audio.playback)))
        await settle { session.state.phase == .failed }
        XCTAssertEqual(audio.starts, 1)
        XCTAssertEqual(audio.mode, "released")
    }

    func testRunCleanupFailureNeverRestoresAudio() async throws {
        let (session, audio, runner) = fixture()
        try await session.start(initialTask: "任务")
        runner.finish(runner.turns[0].run, .failure(TestFailure.cleanup))
        await settle { session.state.phase == .failed }
        XCTAssertTrue(audio.spoken.isEmpty)
        XCTAssertEqual(audio.starts, 1)
        XCTAssertEqual(audio.mode, "released")
    }

    private func fixture() -> (VoiceSession, FakeAudio, FakeRunner) {
        let audio = FakeAudio(), runner = FakeRunner()
        return (VoiceSession(audio: audio, runner: runner), audio, runner)
    }
    private func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 {
            if condition() { return }
            do { try await Task.sleep(for: .milliseconds(1)) } catch { XCTFail("Wait cancelled", file: file, line: line); return }
        }
        XCTFail("State transition timed out", file: file, line: line)
    }
}

private enum TestFailure: Error { case permission, cleanup, presentation }
@MainActor private final class FakeAudio: VoiceAudio {
    var events: (@MainActor (VoiceAudioEvent) -> Void)?
    var startError: Error?
    var stopError: Error?
    var playbackError: Error?
    var playbackContinuation: CheckedContinuation<Void, Never>?
    var holdPlayback = false
    var mode = "released"
    var startEvent: VoiceAudioEvent?
    var holdStart = false
    var startContinuation: CheckedContinuation<Void, Never>?
    var spoken: [String] = []
    var playback: UUID?
    var stops = 0
    func prepare() async throws {
        if let startError { throw startError }
        if holdStart { await withCheckedContinuation { startContinuation = $0 } }
    }
    var starts = 0
    func start(events: @escaping @MainActor (VoiceAudioEvent) -> Void) async throws {
        starts += 1
        mode = "capture"
        self.events = events
        if let startEvent { events(startEvent) }
    }
    func preparePlayback(events: @escaping @MainActor (VoiceAudioEvent) -> Void) async throws {
        if let playbackError { throw playbackError }
        self.events = events
        if holdPlayback { await withCheckedContinuation { playbackContinuation = $0 } }
        mode = "playback"
    }
    func stop() throws {
        if let stopError { throw stopError }
        stops += 1; events = nil; mode = "released"
    }
    func speak(_ text: String) throws -> UUID { spoken.append(text); let id = UUID(); playback = id; return id }
    func stopSpeaking() { playback = nil }
    func emit(_ event: VoiceAudioEvent) { events?(event) }
}
@MainActor private final class FakeRunner: VoiceTaskRunning {
    struct Turn { let run: UUID; let conversation: UUID; let text: String }
    var onStart: (() -> Void)?
    var conversations = 0
    var turns: [Turn] = []
    var stops: [UUID] = []
    var stopReasons: [VoiceStopReason] = []
    var waiters: [UUID: CheckedContinuation<VoiceTurnResult, Error>] = [:]
    var results: [UUID: Result<VoiceTurnResult, Error>] = [:]
    func createConversation() throws -> UUID { conversations += 1; return UUID() }
    func startTurn(_ text: String, conversationID: UUID) throws -> UUID {
        onStart?()
        let id = UUID(); turns.append(Turn(run: id, conversation: conversationID, text: text)); return id
    }
    func waitForTurn(_ runID: UUID, conversationID: UUID) async throws -> VoiceTurnResult {
        if let result = results.removeValue(forKey: runID) { return try result.get() }
        return try await withCheckedThrowingContinuation { waiters[runID] = $0 }
    }
    func requestStop(_ runID: UUID, conversationID: UUID, reason: VoiceStopReason) throws { stops.append(runID); stopReasons.append(reason) }
    func finish(_ id: UUID, _ result: Result<VoiceTurnResult, Error>) {
        if let waiter = waiters.removeValue(forKey: id) { waiter.resume(with: result) }
        else { results[id] = result }
    }
}
