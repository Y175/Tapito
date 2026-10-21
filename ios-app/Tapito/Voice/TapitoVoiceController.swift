import Combine
import Foundation
import UIKit
import AVFAudio
import Speech
import TapitoVoiceCore
import TapitoVoiceAudio

/// The app's single voice entry point, shared by the shortcut and visible controls.
@MainActor final class TapitoVoiceController {
    let session: VoiceSession
    private let model: AgentSessionController
    private let media: StatusPiPController
    private let runner: AppVoiceTaskRunner
    private var latestStep: AgentActivitySnapshot?
    private var heartbeat: Task<Void, Never>?
    private var activitySession: UUID?
    /// Metadata only, to distinguish user stops from audio failures without recording speech.
    private var previousPhase: VoicePhase?
    /// System recording entry must retain a Live Activity for its entire capture lifetime.
    private var requiresRecordingActivity = false
    private var recordingActivityMonitor: Task<Void, Never>?
    /// Lock handling also exists when an intent launches the process without a SwiftUI scene.
    private var protectedDataObservation: AnyCancellable?

    init(model: AgentSessionController, media: StatusPiPController) {
        self.model = model; self.media = media
        runner = AppVoiceTaskRunner(model: model)
        let audio: any VoiceAudio
        #if DEBUG && targetEnvironment(simulator)
        if SimulatorVoiceFixture.enabled { audio = SimulatorVoiceFixture() }
        else { audio = AppleVoiceAudio(beforeActivation: { try await media.prepareForVoice() }, diagnostic: { BackgroundExecutionTrace.record($0) }) }
        #else
        audio = AppleVoiceAudio(beforeActivation: { try await media.prepareForVoice() }, diagnostic: { BackgroundExecutionTrace.record($0) })
        #endif
        session = VoiceSession(audio: audio, runner: runner)
        session.onDiagnostic = { BackgroundExecutionTrace.record($0) }
        runner.onDrain = { [weak self] in
            guard let self else { return }
            self.media.setVoiceSessionActive(self.session.state.phase.isActive)
            if !self.session.state.phase.isActive { self.runner.releaseConversation() }
        }
        runner.onActivity = { [weak self] snapshot in
            self?.latestStep = snapshot; self?.publishActivity()
        }
        session.onChange = { [weak self] state in self?.changed(state) }
        session.onCaptureActivity = { [weak self] active in
            guard let self else { return }
            // Capture is observation only, never background execution authority.
            self.model.voiceCaptureActive = active
        }
        session.prepareCapture = { [weak self] in
            guard let self else { throw CancellationError() }
            guard self.requiresRecordingActivity else { return }
            guard let id = self.session.state.sessionID else { throw AppError.invalid("语音会话身份缺失") }
            try await self.model.liveActivities.requireActiveActivity(for: id)
            try Task.checkCancellation()
            guard self.session.state.sessionID == id, self.session.state.phase == .preparing else { throw CancellationError() }
            self.monitorRecordingActivity(id)
        }
        protectedDataObservation = NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)
            .sink { [weak self] _ in
                self?.deviceLocked()
                self?.model.setProtectedDataAvailable(false)
            }
    }

    /// Shortcut text continues the existing conversation; a new session needs a foreground start.
    func execute(_ text: String = "") async throws {
        if session.state.phase.isActive {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppError.invalid("连续语音会话已开启")
            }
            try session.submit(text)
        } else {
            guard UIApplication.shared.applicationState == .active,
                  UIApplication.shared.isProtectedDataAvailable else {
                throw AppError.unavailable("请解锁并打开 Tapito 后开始语音对话")
            }
            guard !model.hasBusySessions else { throw AppError.invalid("请先停止正在运行的任务") }
            try await session.start(initialTask: text)
        }
    }

    /// Called only by the system's AudioRecordingIntent; never brings a scene to the front.
    func startFromRecordingIntent() async throws {
        guard UIApplication.shared.isProtectedDataAvailable else { throw AppError.unavailable("请先解锁 iPhone 再开始语音任务") }
        var authorized = AVAudioApplication.shared.recordPermission == .granted &&
            SFSpeechRecognizer.authorizationStatus() == .authorized
        #if DEBUG && targetEnvironment(simulator)
        if SimulatorVoiceFixture.enabled { authorized = true }
        #endif
        guard authorized else {
            throw AppError.unavailable("请先在 Tapito 中点一次“开始连续语音”，完成麦克风与语音识别授权，再使用操作按钮")
        }
        try BackgroundLocationAccess.shared.requireAuthorization()
        guard !session.state.phase.isActive else { throw AppError.invalid("语音会话已开启，请在灵动岛结束后再开始") }
        guard !model.hasBusySessions else { throw AppError.invalid("请等待当前任务结束，或先点击结束") }
        // A background launch must not inherit the model's initial foreground assumption.
        model.setScene(UIApplication.shared.applicationState == .active ? .active : .background)
        model.setProtectedDataAvailable(true)
        requiresRecordingActivity = true
        BackgroundExecutionTrace.record("voice.intentStart foreground=\(UIApplication.shared.applicationState == .active)")
        var startedSessionID: UUID?
        do {
            try await session.start()
            startedSessionID = session.state.sessionID
            try Task.checkCancellation()
            guard session.state.phase.isActive else { throw AppError.unavailable(session.state.error ?? "语音启动已取消") }
            await model.liveActivities.waitForPendingUpdates()
            guard session.state.sessionID == startedSessionID, session.state.phase.isActive else {
                throw AppError.unavailable("语音启动已取消")
            }
            BackgroundExecutionTrace.record("voice.intentStarted foreground=\(UIApplication.shared.applicationState == .active)")
        } catch {
            let failure = error as NSError
            BackgroundExecutionTrace.record("voice.intentFailed domain=\(failure.domain) code=\(failure.code)")
            // A delayed completion from this invocation cannot terminate a replacement session.
            if let startedSessionID, session.state.sessionID == startedSessionID, session.state.phase.isActive {
                session.fail(error.localizedDescription)
            }
            if !session.state.phase.isActive { requiresRecordingActivity = false }
            await model.liveActivities.waitForPendingUpdates()
            throw error
        }
    }

    /// Activity dismissal revokes microphone capture and subsequent task dispatch.
    private func monitorRecordingActivity(_ id: UUID) {
        recordingActivityMonitor?.cancel()
        recordingActivityMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.session.state.sessionID == id, self.session.state.phase.isActive else { return }
                guard self.model.liveActivities.hasActiveActivity(for: id) else {
                    self.session.fail("语音实时活动已关闭，录音和后续操作已停止")
                    return
                }
            }
        }
    }

    func deviceLocked() {
        if session.state.phase.isActive { session.fail("设备已锁定，语音和后续操作已停止；解锁后请重新开始") }
    }

    private func changed(_ state: VoiceState) {
        if !state.phase.isActive {
            requiresRecordingActivity = false
            recordingActivityMonitor?.cancel(); recordingActivityMonitor = nil
        }
        if previousPhase != state.phase {
            previousPhase = state.phase
            BackgroundExecutionTrace.record("voice.phase value=\(state.phase.rawValue)")

        }
        if activitySession != state.sessionID {
            activitySession = state.sessionID; latestStep = nil
        }
        // Keep legacy playback disabled until the explicit voice session ends, including pause.
        media.setVoiceSessionActive(state.phase.isActive || runner.hasPendingTurn)
        publishActivity()
        if state.phase.isActive, state.phase != .paused {
            if heartbeat == nil {
                heartbeat = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(10)) } catch { return }
                        guard let self else { return }
                        self.publishActivity()
                    }
                }
            }
        } else {
            heartbeat?.cancel(); heartbeat = nil
            if !state.phase.isActive { runner.releaseConversation() }
        }
    }

    private func publishActivity() {
        let voice = session.state
        guard let sessionID = voice.sessionID, let conversation = voice.conversationID else { return }
        let phase: AgentActivityAttributes.Phase
        switch voice.phase {
        case .idle: return
        case .preparing: phase = .voicePreparing
        case .listening: phase = .listening
        case .executing:
            if let step = latestStep, !step.state.phase.isTerminal { phase = step.state.phase }
            else { phase = .thinking }
        case .interrupting: phase = .pausing
        case .speaking: phase = .speaking
        case .paused: phase = .paused
        case .failed: phase = .blocked
        case .ended: phase = .stopped
        }
        let now = Date()
        let executing = voice.phase == .executing
        let content = AgentActivityAttributes.ContentState(
            phase: phase, completedTools: latestStep?.state.completedTools ?? 0,
            approvalID: executing ? latestStep?.state.approvalID : nil, updatedAt: now,
            operation: executing ? latestStep?.state.operation : nil,
            isVoiceSession: true, voiceRunID: latestStep?.attributes.runID,
            step: executing ? latestStep?.state.step : nil)
        model.liveActivities.submit(AgentActivitySnapshot(
            attributes: .init(sessionID: conversation, runID: sessionID, isDemo: false),
            state: content, staleDate: phase == .paused ? .distantFuture : now.addingTimeInterval(30)))
    }
}

/// Adapts the existing run lifecycle, including synchronous revocation and asynchronous drain.
@MainActor private final class AppVoiceTaskRunner: VoiceTaskRunning {
    var onActivity: ((AgentActivitySnapshot) -> Void)?
    /// Keep legacy media suppressed through manual stop's asynchronous cleanup.
    var onDrain: (() -> Void)?
    var hasPendingTurn: Bool {
        guard let conversationID, let worker = model.existingExecutionModel(for: conversationID) else { return false }
        return worker.running || worker.stopping
    }
    private let model: AgentSessionController
    private var conversationID: UUID?
    private var requestedStops: Set<UUID> = []
    init(model: AgentSessionController) { self.model = model }

    func createConversation() throws -> UUID {
        guard !model.hasBusySessions else { throw AppError.invalid("另一个任务正在执行，语音未开始") }
        let id = model.createConversationDraft(mode: .live)
        guard model.selectedProvider(in: id) != nil else {
            model.discardConversationDraft(id)
            throw AppError.invalid("请先在设置中配置供应商并选择默认模型")
        }
        conversationID = id; model.voiceConversationID = id
        let worker = model.executionModel(for: id)
        worker.voiceManaged = true
        worker.voiceActivityHandler = { [weak self] in self?.onActivity?($0) }
        return id
    }

    func startTurn(_ text: String, conversationID: UUID) throws -> UUID {
        guard self.conversationID == conversationID else { throw AppError.invalid("语音会话已失效") }
        guard !model.voiceCaptureActive else { throw AppError.invalid("麦克风尚未释放，任务未开始") }
        let worker = model.executionModel(for: conversationID)
        guard worker.send(text, in: conversationID, cloudConsent: true, allowBackgroundStart: true, voiceTurn: true),
              let identity = worker.ownedRun else {
            throw AppError.unavailable(worker.errorMessage ?? "任务没有生成运行记录")
        }
        return identity.runID
    }

    func waitForTurn(_ runID: UUID, conversationID: UUID) async throws -> VoiceTurnResult {
        guard let worker = model.existingExecutionModel(for: conversationID) else { throw AppError.invalid("执行会话不存在") }
        // stop() revokes immediately, but transport/agent cleanup still owns the worker until stopping is false.
        while worker.running || worker.stopping {
            if let current = worker.ownedRun, current.runID != runID { throw AppError.invalid("语音运行身份发生变化") }
            try await Task.sleep(for: .milliseconds(50))
        }
        onDrain?()
        BackgroundExecutionTrace.record("voice.runDrained run=\(runID) workerBusy=false")
        if requestedStops.remove(runID) != nil { return .init(response: "已停止后续操作；已发出的动作请核对设备") }
        guard let record = model.sessions.conversation(conversationID) else { throw AppError.invalid("会话记录已移除") }
        let response = record.messages.last(where: { $0.runID == runID && $0.role == .assistant && $0.state == .complete && !$0.text.isEmpty })?.text
        guard record.phase == .completed, let response else {
            let notice = record.messages.last(where: { $0.runID == runID && $0.role == .notice })?.text
            throw AppError.unavailable(worker.errorMessage ?? notice ?? "本轮已中断，请回到会话查看执行记录")
        }
        return .init(response: response)
    }

    func requestStop(_ runID: UUID, conversationID: UUID, reason: VoiceStopReason) throws {
        guard let worker = model.existingExecutionModel(for: conversationID) else { throw AppError.invalid("执行会话不存在") }
        if let current = worker.ownedRun, current.runID != runID { throw AppError.invalid("不能停止其他轮次的任务") }
        guard requestedStops.insert(runID).inserted else { return }
        if worker.ownedRun?.runID == runID {
            let message: String
            switch reason {
            case .pause: message = "连续语音已暂停，当前任务已停止"
            case .end: message = "连续语音已结束，当前任务已停止"
            case .failure: message = "语音出现异常，当前任务已停止；请查看语音栏提示"
            }
            BackgroundExecutionTrace.record("voice.stop reason=\(reason.rawValue)")
            worker.stop(message: message + "；已发出的操作不会自动撤销或重发")
        }
    }

    func releaseConversation() {
        // Retain the reservation and media suppression while stop cleanup is running.
        guard !hasPendingTurn, let id = conversationID else { return }
        let worker = model.existingExecutionModel(for: id)
        worker?.voiceManaged = false; worker?.voiceActivityHandler = nil
        model.voiceConversationID = nil; conversationID = nil
        model.discardConversationDraft(id)
    }
}
