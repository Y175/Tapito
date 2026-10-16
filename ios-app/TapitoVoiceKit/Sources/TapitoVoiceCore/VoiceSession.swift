import Combine
import Foundation

/// Public phases of one explicitly activated voice conversation.
public enum VoicePhase: String, Sendable {
    case idle, preparing, listening, executing, interrupting, speaking, paused, failed, ended
    public var isActive: Bool { ![.idle, .failed, .ended].contains(self) }
}

/// Presentation state; never persists microphone audio or executable actions.
public struct VoiceState: Equatable, Sendable {
    /// Fences audio callbacks and results from older voice sessions.
    public var sessionID: UUID?
    /// Stable chat identity across spoken turns and corrections.
    public var conversationID: UUID?
    /// Current voice interaction, independent of tool delivery success.
    public var phase: VoicePhase = .idle
    /// Latest transcription, visible only inside the app.
    public var transcript = ""
    /// Actionable failure text; a failure never silently starts a replacement task.
    public var error: String?
    public init() {}
}

/// Events from the speech adapter. Output completion carries its own identity.
public enum VoiceAudioEvent: Sendable {
    case partial(String), utterance(String), playbackFinished(UUID), captureActive(Bool), failure(String)
}

/// Audio owns mutually exclusive capture and playback; execution owns neither.
@MainActor public protocol VoiceAudio: AnyObject {
    /// Obtain permission and validate recognition resources without opening the microphone.
    func prepare() async throws
    func start(events: @escaping @MainActor (VoiceAudioEvent) -> Void) async throws
    /// Activate output only, after the device run has released its screen session.
    func preparePlayback(events: @escaping @MainActor (VoiceAudioEvent) -> Void) async throws
    func stop() throws
    func speak(_ text: String) throws -> UUID
    func stopSpeaking()
}

/// One model turn can finish with a response without proving task success.
public struct VoiceTurnResult: Sendable {
    /// User-facing answer, never private reasoning or raw tool arguments.
    public let response: String
    /// A blocked/interrupted run requires explicit user recovery.
    public let needsAttention: Bool
    public init(response: String, needsAttention: Bool = false) {
        self.response = response; self.needsAttention = needsAttention
    }
}

/// Explicit user stops and failures revoke a turn without starting a replacement.
public enum VoiceStopReason: String, Sendable {
    case pause, end, failure
}

/// Device execution keeps its own stop fence and unknown-outcome safeguards.
@MainActor public protocol VoiceTaskRunning: AnyObject {
    func createConversation() throws -> UUID
    func startTurn(_ text: String, conversationID: UUID) throws -> UUID
    func waitForTurn(_ runID: UUID, conversationID: UUID) async throws -> VoiceTurnResult
    /// Synchronously revoke dispatch before any asynchronous cleanup.
    func requestStop(_ runID: UUID, conversationID: UUID, reason: VoiceStopReason) throws
}

/// Coordinates spoken turns without overlapping device runs or replaying actions.
@MainActor public final class VoiceSession: ObservableObject {
    /// UI and Live Activity adapters observe this state.
    @Published public private(set) var state = VoiceState()
    /// Public state changes; the app can publish generic system-visible status.
    public var onChange: ((VoiceState) -> Void)?
    /// Reports actual capture activity separately from user intent to listen.
    public var onCaptureActivity: ((Bool) -> Void)?
    /// Establish required system presentation after permission, before any microphone input.
    public var prepareCapture: (() async throws -> Void)?
    private let audio: any VoiceAudio
    private let runner: any VoiceTaskRunning
    private var runID: UUID?
    private var runTask: Task<Void, Never>?
    private var playbackID: UUID?
    private var pauseAfterDrain = false
    private var startingAudio = false
    private var audioEpoch = UUID()
    /// Metadata-only transition events; never include speech or model content.
    public var onDiagnostic: ((String) -> Void)?

    public init(audio: any VoiceAudio, runner: any VoiceTaskRunning) {
        self.audio = audio; self.runner = runner
    }

    /// Must be invoked by a user action. Permission or startup failures are visible.
    public func start(initialTask: String = "") async throws {
        guard !state.phase.isActive, runTask == nil, !startingAudio else { throw failure("上一段语音会话仍在结束，请稍后再试") }
        let text = try validated(initialTask, allowEmpty: true)
        let token = UUID(), capture = UUID()
        startingAudio = true; audioEpoch = capture; pauseAfterDrain = false
        defer { startingAudio = false }
        state = VoiceState(); state.sessionID = token
        setPhase(.preparing)
        do {
            try await audio.prepare()
            try Task.checkCancellation()
            guard try isStillPreparing(token) else { return }
            state.conversationID = try runner.createConversation()
            publish()
            try await prepareCapture?()
            try Task.checkCancellation()
            // Ending from a Live Activity while its initial update is pending wins over capture.
            guard try isStillPreparing(token) else { return }
            try await audio.start { [weak self] event in
                guard let self, self.state.sessionID == token, self.audioEpoch == capture, self.state.phase.isActive else { return }
                self.receive(event)
            }
            // End/lock may win while an operating-system permission prompt is open.
            guard state.sessionID == token, state.phase == .preparing else {
                try audio.stop()
                if state.phase == .failed { throw failure(state.error ?? "语音启动失败") }
                return
            }
            setPhase(.listening)
            if !text.isEmpty { try submit(text) }
        } catch {
            if state.sessionID == token, audioEpoch == capture, state.phase.isActive { fail(error.localizedDescription) }
            throw error
        }
    }

    /// An intentional end cancels startup; a lock or preparation failure remains an error.
    private func isStillPreparing(_ sessionID: UUID) throws -> Bool {
        guard state.sessionID == sessionID else { throw failure("语音会话身份已改变，启动已停止") }
        if state.phase == .failed { throw failure(state.error ?? "语音启动失败") }
        return state.phase == .preparing
    }

    /// A shortcut invoked during an active session becomes a new spoken turn.
    public func submit(_ text: String) throws {
        let text = try validated(text)
        guard state.phase.isActive, state.phase != .preparing, state.phase != .paused else {
            throw failure("请先开始或恢复语音会话")
        }
        guard state.phase == .listening else {
            throw failure("当前任务或播报尚未结束，请等待完成，或点击“结束”")
        }
        if isEndCommand(text) { end(); return }
        state.transcript = text
        try beginTurn(text)
    }

    /// Suspend capture and execution; resume never resumes device actions by itself.
    public func pause() {
        guard state.phase.isActive, state.phase != .paused else { return }
        playbackID = nil; pauseAfterDrain = true
        audioEpoch = UUID()
        if let runID, let conversation = state.conversationID {
            do { try runner.requestStop(runID, conversationID: conversation, reason: .pause) }
            catch { fail(error.localizedDescription); return }
        }
        do { try audio.stop() } catch { fail(error.localizedDescription); return }
        onCaptureActivity?(false)
        setPhase(runID == nil ? .paused : .interrupting)
    }

    /// Reacquire audio explicitly after pause; do not replay the interrupted turn.
    public func resume() async throws {
        guard state.phase == .paused, !startingAudio, let token = state.sessionID else { throw failure("当前没有可恢复的语音会话，或麦克风仍在释放") }
        let capture = UUID(); audioEpoch = capture; startingAudio = true
        defer { startingAudio = false }
        pauseAfterDrain = false; setPhase(.preparing)
        do {
            try await audio.prepare()
            try Task.checkCancellation()
            guard try isStillPreparing(token) else { return }
            try await prepareCapture?()
            try Task.checkCancellation()
            guard try isStillPreparing(token) else { return }
            try await audio.start { [weak self] event in
                guard let self, self.state.sessionID == token, self.audioEpoch == capture, self.state.phase.isActive else { return }
                self.receive(event)
            }
            guard state.sessionID == token, state.phase == .preparing else {
                try audio.stop()
                if state.phase == .failed { throw failure(state.error ?? "语音恢复失败") }
                return
            }
            setPhase(.listening)
        } catch {
            if audioEpoch == capture, state.phase.isActive { fail(error.localizedDescription) }
            throw error
        }
    }

    /// End listening and revoke future dispatch; already-sent actions stay recorded.
    public func end() {
        guard state.phase.isActive else { return }
        playbackID = nil
        audioEpoch = UUID()
        var errors: [String] = []
        if let runID, let conversation = state.conversationID {
            do { try runner.requestStop(runID, conversationID: conversation, reason: .end) }
            catch { errors.append(error.localizedDescription) }
        }
        do { try audio.stop() } catch { errors.append(error.localizedDescription) }
        onCaptureActivity?(false)
        state.error = errors.isEmpty ? nil : errors.joined(separator: "\n")
        setPhase(errors.isEmpty ? .ended : .failed)
    }

    /// A delayed system button may only end the exact voice session it displayed.
    public func end(sessionID: UUID) throws {
        guard state.sessionID == sessionID else { throw failure("这段语音会话已失效，未停止当前会话") }
        end()
        if let error = state.error { throw failure(error) }
    }

    /// Lock, audio interruption and route loss require explicit recovery.
    public func fail(_ message: String) {
        playbackID = nil
        audioEpoch = UUID()
        var messages = [message]
        if let runID, let conversation = state.conversationID {
            do { try runner.requestStop(runID, conversationID: conversation, reason: .failure) }
            catch { messages.append(error.localizedDescription) }
        }
        do { try audio.stop() } catch { messages.append(error.localizedDescription) }
        onCaptureActivity?(false)
        state.error = messages.joined(separator: "\n"); setPhase(.failed)
    }

    private func receive(_ event: VoiceAudioEvent) {
        switch event {
        case .captureActive(let active): onCaptureActivity?(active)
        case .failure(let message): fail(message)
        case .partial(let text):
            guard state.phase == .listening, !text.isEmpty else { return }
            state.transcript = text; publish()
        case .utterance(let text):
            guard state.phase == .listening else { return }
            do { try submit(text) } catch { fail(error.localizedDescription) }
        case .playbackFinished(let id):
            guard playbackID == id, state.phase == .speaking else { return }
            playbackID = nil
            resumeListeningAfterPlayback()
        }
    }

    private func beginTurn(_ text: String) throws {
        guard runID == nil, let conversation = state.conversationID, let token = state.sessionID else {
            throw failure("语音会话状态无效，未发送任务")
        }
        // Invalidate queued recognition first. CoreDevice 9022 forbids mirroring
        // while a microphone is in use; dropping recognition results is insufficient.
        audioEpoch = UUID()
        do {
            try audio.stop()
            onCaptureActivity?(false)
            onDiagnostic?("voice.audioReleased reason=execution")
            let id = try runner.startTurn(text, conversationID: conversation)
            runID = id; state.error = nil; setPhase(.executing)
            onDiagnostic?("voice.turnStarted run=\(id)")
            runTask = Task { [weak self, runner] in
                let result: Result<VoiceTurnResult, Error>
                do { result = .success(try await runner.waitForTurn(id, conversationID: conversation)) }
                catch { result = .failure(error) }
                guard let self, self.state.sessionID == token, self.runID == id else { return }
                self.runID = nil; self.runTask = nil
                guard self.state.phase.isActive else { return }
                if self.pauseAfterDrain {
                    if case .failure(let error) = result { self.fail(error.localizedDescription); return }
                    self.setPhase(.paused); return
                }
                switch result {
                case .failure(let error): self.fail(error.localizedDescription)
                case .success(let answer):
                    if answer.needsAttention { self.fail(answer.response); return }
                    await self.playAnswer(answer.response, sessionID: token)
                }
            }
        } catch {
            fail(error.localizedDescription)
            throw error
        }
    }

    /// No output is activated until waitForTurn has drained the screen transport.
    private func playAnswer(_ text: String, sessionID: UUID) async {
        let capture = UUID(); audioEpoch = capture; startingAudio = true
        defer { startingAudio = false }
        do {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw failure("本轮没有返回结果说明，请查看会话")
            }
            onDiagnostic?("voice.turnDrained preparing=playback")
            try await audio.preparePlayback { [weak self] event in
                guard let self, self.state.sessionID == sessionID, self.audioEpoch == capture, self.state.phase.isActive else { return }
                self.receive(event)
            }
            guard state.sessionID == sessionID, audioEpoch == capture, state.phase == .executing else {
                try audio.stop(); return
            }
            playbackID = try audio.speak(text)
            setPhase(.speaking)
        } catch {
            if audioEpoch == capture, state.phase.isActive { fail(error.localizedDescription) }
        }
    }

    /// Restart a fresh recognition epoch only after playback has fully released audio.
    private func resumeListeningAfterPlayback() {
        guard !startingAudio, let token = state.sessionID else { return }
        let capture = UUID(); audioEpoch = capture; startingAudio = true
        setPhase(.preparing)
        Task { [weak self] in
            guard let self else { return }
            defer { self.startingAudio = false }
            do {
                try self.audio.stop()
                self.onCaptureActivity?(false)
                self.onDiagnostic?("voice.audioReleased reason=playbackFinished")
                try await self.audio.prepare()
                guard self.audioEpoch == capture, self.state.phase == .preparing else { return }
                try await self.prepareCapture?()
                guard self.state.sessionID == token, self.audioEpoch == capture,
                      self.state.phase == .preparing else { return }
                try await self.audio.start { [weak self] event in
                    guard let self, self.state.sessionID == token, self.audioEpoch == capture, self.state.phase.isActive else { return }
                    self.receive(event)
                }
                guard self.state.sessionID == token, self.audioEpoch == capture,
                      self.state.phase == .preparing else { try self.audio.stop(); return }
                self.setPhase(.listening)
            } catch {
                if self.audioEpoch == capture, self.state.phase.isActive { self.fail(error.localizedDescription) }
            }
        }
    }

    private func setPhase(_ phase: VoicePhase) { state.phase = phase; publish() }
    private func publish() { onChange?(state) }
    private func validated(_ text: String, allowEmpty: Bool = false) throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (allowEmpty || !value.isEmpty), value.count <= 2_000 else {
            throw failure("每条语音指令需要 1–2,000 个字符，请分句表达")
        }
        return value
    }
    private func normalized(_ text: String) -> String {
        text.components(separatedBy: .punctuationCharacters.union(.whitespacesAndNewlines)).joined().lowercased()
    }
    private func isEndCommand(_ text: String) -> Bool { ["结束对话", "停止对话", "退出语音", "endconversation"].contains(normalized(text)) }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "Tapito.Voice", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
