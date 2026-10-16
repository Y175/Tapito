// ActivityKit's reference type predates Sendable. All mutations below are
// serialized by tail; no Activity reference is exposed to another owner.
@preconcurrency import ActivityKit
import Foundation
import OSLog

/// Request return, system content change and widget evaluation are separate
/// events. None of them alone acknowledges pixels displayed in the island.
@MainActor private enum AgentActivityTrace {
    private static let logger = Logger(subsystem: "com.y175.tapito", category: "ActivityLifecycle")
    static func record(_ event: String) {
        logger.info("\(event, privacy: .public)")
        BackgroundExecutionTrace.record(event)
    }
}

struct AgentActivitySnapshot: Equatable {
    let attributes: AgentActivityAttributes
    let state: AgentActivityAttributes.ContentState
    let staleDate: Date
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.attributes.sessionID == rhs.attributes.sessionID && lhs.attributes.runID == rhs.attributes.runID &&
        lhs.attributes.isDemo == rhs.attributes.isDemo && lhs.state == rhs.state && lhs.staleDate == rhs.staleDate
    }
}

@MainActor protocol AgentActivityHandle: AnyObject {
    var isActive: Bool { get }
    func update(_ content: ActivityContent<AgentActivityAttributes.ContentState>, alert: AlertConfiguration?) async
    func end(_ content: ActivityContent<AgentActivityAttributes.ContentState>, dismissAt: Date) async
}

@MainActor private final class SystemAgentActivity: AgentActivityHandle {
    let activity: Activity<AgentActivityAttributes>
    private var serial = 0
    private var contentObservation: Task<Void, Never>?
    private var stateObservation: Task<Void, Never>?
    init(_ activity: Activity<AgentActivityAttributes>) {
        self.activity = activity
        AgentActivityTrace.record("activity.handle id=\(activity.id) run=\(activity.attributes.runID)")
        contentObservation = Task { [weak self, activity] in
            for await content in activity.contentUpdates {
                guard self != nil else { return }
                AgentActivityTrace.record("activity.contentObserved id=\(activity.id) run=\(activity.attributes.runID) phase=\(content.state.phase) operation=\(content.state.operation?.rawValue ?? "none") tools=\(content.state.completedTools) contentTime=\(content.state.updatedAt.timeIntervalSince1970)")
            }
        }
        stateObservation = Task { [weak self, activity] in
            for await state in activity.activityStateUpdates {
                guard self != nil else { return }
                AgentActivityTrace.record("activity.stateObserved id=\(activity.id) run=\(activity.attributes.runID) state=\(state)")
            }
        }
    }
    deinit { contentObservation?.cancel(); stateObservation?.cancel() }
    var isActive: Bool { activity.activityState == .active || activity.activityState == .stale }
    func update(_ content: ActivityContent<AgentActivityAttributes.ContentState>, alert: AlertConfiguration?) async {
        serial += 1
        let write = serial
        AgentActivityTrace.record("activity.writeBegin id=\(activity.id) run=\(activity.attributes.runID) serial=\(write) method=update phase=\(content.state.phase) operation=\(content.state.operation?.rawValue ?? "none") tools=\(content.state.completedTools) alert=\(alert != nil) contentTime=\(content.state.updatedAt.timeIntervalSince1970)")
        await activity.update(content, alertConfiguration: alert)
        AgentActivityTrace.record("activity.systemUpdateReturned id=\(activity.id) run=\(activity.attributes.runID) serial=\(write) requested=\(content.state.phase) observed=\(activity.content.state.phase) state=\(activity.activityState)")
    }
    func end(_ content: ActivityContent<AgentActivityAttributes.ContentState>, dismissAt: Date) async {
        serial += 1
        let write = serial
        AgentActivityTrace.record("activity.writeBegin id=\(activity.id) run=\(activity.attributes.runID) serial=\(write) method=end phase=\(content.state.phase) contentTime=\(content.state.updatedAt.timeIntervalSince1970)")
        await activity.end(content, dismissalPolicy: dismissAt <= Date() ? .immediate : .after(dismissAt))
        AgentActivityTrace.record("activity.systemEndReturned id=\(activity.id) run=\(activity.attributes.runID) serial=\(write) requested=\(content.state.phase) observed=\(activity.content.state.phase) state=\(activity.activityState)")
    }
}

/// Single FIFO owns ActivityKit writes, including launch reconciliation. Neither
/// suspension nor a Live Activity grants the executor background time.
@MainActor final class AgentLiveActivityController: ObservableObject {
    @Published private(set) var notice: String?
    private var foreground = true
    private let enabled: Bool
    private var activities: [UUID: any AgentActivityHandle] = [:]
    private let createActivity: ((AgentActivitySnapshot) throws -> any AgentActivityHandle)?
    private var terminalPresented: Set<UUID> = []
    private var executionPresented: Set<UUID> = []
    private var writtenContent: [ObjectIdentifier: ActivityContent<AgentActivityAttributes.ContentState>] = [:]
    private var tail: Task<Void, Never>?
    private var submissionRevision = 0
    private var latest: [UUID: AgentActivitySnapshot] = [:]
    init(enabled: Bool = true, createActivity: ((AgentActivitySnapshot) throws -> any AgentActivityHandle)? = nil) {
        self.enabled = enabled
        self.createActivity = createActivity
        BackgroundExecutionTrace.record("activity.init enabled=\(enabled)")
        guard enabled, createActivity == nil else { return }
        // A new process has no resumable continuation. Never adopt an old run.
        let orphans = Activity<AgentActivityAttributes>.activities
        tail = Task {
            for orphan in orphans {
                var state = orphan.content.state
                if !state.phase.isTerminal { state.phase = .interrupted }
                state.approvalID = nil; state.operation = nil; state.updatedAt = Date()
                // Remove legacy empty standby and ended voice cards during upgrade/relaunch.
                let dismissal: ActivityUIDismissalPolicy = orphan.content.state.phase == .standby || state.isVoiceSession == true
                    ? .immediate : .after(Date().addingTimeInterval(300))
                await orphan.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: dismissal)
                BackgroundExecutionTrace.record("activity.recovered phase=\(state.phase)")
            }
        }
    }

    #if DEBUG
    var activeCountForProbe: Int {
        activities.values.filter(\.isActive).count
    }
    #endif

    func setForeground(_ active: Bool) {
        if foreground != active { AgentActivityTrace.record("activity.scene foreground=\(active)") }
        foreground = active
        // Returning to the App acknowledges the terminal presentation.
        if active { for snapshot in latest.values where snapshot.state.phase.isTerminal { submit(snapshot) } }
    }

    private func executionAlert(_ snapshot: AgentActivitySnapshot) -> AlertConfiguration? {
        let run = snapshot.attributes.runID
        // Recording must own an activity before capture; alert only when it is ready to listen.
        // A preparation alert followed immediately by listening can consume the one-time prompt.
        if snapshot.state.isVoiceSession == true, snapshot.state.phase == .voicePreparing { return nil }
        guard !foreground, snapshot.state.phase != .standby, !snapshot.state.phase.isTerminal,
              executionPresented.insert(run).inserted else { return nil }
        // An alerting update requests a brief expanded presentation. The system
        // owns its duration; progress updates must not repeatedly interrupt it.
        if snapshot.state.isVoiceSession == true, snapshot.state.phase == .listening {
            return AlertConfiguration(title: "可以开始说话", body: "长按灵动岛可结束语音", sound: .default)
        }
        return AlertConfiguration(title: "任务开始处理", body: "\(snapshot.state.title)", sound: .default)
    }

    private func update(_ activity: any AgentActivityHandle,
                        content: ActivityContent<AgentActivityAttributes.ContentState>, alert: AlertConfiguration?) async {
        let key = ObjectIdentifier(activity)
        if alert == nil, !content.state.phase.isTerminal, let previous = writtenContent[key] {
            var previousState = previous.state
            previousState.updatedAt = content.state.updatedAt
            let sameExpiry = previous.staleDate == content.staleDate
            let deferredHeartbeat: Bool
            if content.state.phase != .awaitingApproval, let old = previous.staleDate, let new = content.staleDate {
                let extensionInterval = new.timeIntervalSince(old)
                deferredHeartbeat = extensionInterval >= 0 && extensionInterval < 15
            } else { deferredHeartbeat = false }
            if previousState == content.state && (sameExpiry || deferredHeartbeat) {
                AgentActivityTrace.record("activity.updateSkipped reason=unchanged phase=\(content.state.phase)")
                return
            }
        }
        await activity.update(content, alert: alert)
        writtenContent[key] = content
    }

    func submit(_ snapshot: AgentActivitySnapshot) {
        latest[snapshot.attributes.runID] = snapshot
        guard enabled else {
            BackgroundExecutionTrace.record("activity.skipped disabled=true")
            return
        }
        let previous = tail
        submissionRevision += 1
        tail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.apply(snapshot)
        }
    }

    /// Keep the caller's execution capability until its queued update returns.
    func waitForPendingUpdates() async {
        // An initial snapshot can be superseded while an older write is in
        // flight. Drain its replacement too before releasing the intent scope.
        var revision: Int
        repeat {
            revision = submissionRevision
            await tail?.value
        } while revision != submissionRevision
    }

    /// Recording intents require a live system handle, not merely a queued snapshot.
    func requireActiveActivity(for runID: UUID) async throws {
        await waitForPendingUpdates()
        guard hasActiveActivity(for: runID) else {
            throw AppError.unavailable("无法建立语音实时活动，麦克风未启动。" + (notice ?? "请开启 Tapito 的实时活动后重试"))
        }
    }

    /// Capture is eligible only while this exact voice session owns an active activity.
    func hasActiveActivity(for runID: UUID) -> Bool {
        guard let snapshot = latest[runID], !snapshot.state.phase.isTerminal else { return false }
        return activities[runID]?.isActive == true
    }

    private func apply(_ snapshot: AgentActivitySnapshot) async {
        let run = snapshot.attributes.runID
        if !snapshot.state.phase.isTerminal {
            guard latest[run] == snapshot else { return }
            let voiceStartup = snapshot.state.isVoiceSession == true &&
                [.voicePreparing, .listening].contains(snapshot.state.phase)
            if snapshot.state.phase != .awaitingApproval, !voiceStartup,
               activities[run] != nil {
                // Tool and stream events often alternate within milliseconds.
                // Coalesce obsolete progress without delaying an approval gate.
                try? await Task.sleep(for: .milliseconds(300))
                guard latest[run] == snapshot else { return }
            }
        }
        if snapshot.state.phase.isTerminal {
            AgentActivityTrace.record("activity.terminalRequested run=\(run) phase=\(snapshot.state.phase) foreground=\(foreground) active=\(activities[run]?.isActive == true)")
            if let current = activities[run] {
                if !foreground, snapshot.state.phase != .stopped {
                    // end(.after) only retains the Lock Screen card. Keep the
                    // terminal island until foreground or the next run instead.
                    let alert = snapshot.state.phase == .completed && !terminalPresented.contains(run)
                        ? AlertConfiguration(title: "任务已完成", body: "点击查看任务结果", sound: .default) : nil
                    await update(current, content: ActivityContent(state: snapshot.state, staleDate: nil, relevanceScore: 100), alert: alert)
                    terminalPresented.insert(run)
                    BackgroundExecutionTrace.record("activity.terminalUpdateReturned phase=\(snapshot.state.phase) alertRequested=\(alert != nil)")
                } else {
                    // Explicit stop removes both island and Lock Screen card, with no idle replacement.
                    let dismissAt = snapshot.state.phase == .stopped ? Date() : Date().addingTimeInterval(300)
                    await current.end(ActivityContent(state: snapshot.state, staleDate: nil), dismissAt: dismissAt)
                    BackgroundExecutionTrace.record("activity.ended phase=\(snapshot.state.phase) foreground=\(foreground)")
                    writtenContent.removeValue(forKey: ObjectIdentifier(current))
                    activities.removeValue(forKey: run)
                    latest.removeValue(forKey: run)
                    terminalPresented.remove(run)
                    executionPresented.remove(run)
                }
            } else {
                BackgroundExecutionTrace.record("activity.terminalSkipped phase=\(snapshot.state.phase) reason=noActivity")
                latest.removeValue(forKey: run)
            }
            return
        }
        // Suppress queued obsolete updates and never start after cancellation.
        guard latest[run] == snapshot else { return }
        if activities[run] == nil {
            for previous in Array(latest.values) where previous.attributes.runID != run && previous.state.phase.isTerminal {
                let previousRun = previous.attributes.runID
                if let activity = activities.removeValue(forKey: previousRun) {
                    await activity.end(ActivityContent(state: previous.state, staleDate: nil), dismissAt: Date().addingTimeInterval(300))
                    writtenContent.removeValue(forKey: ObjectIdentifier(activity))
                }
                latest.removeValue(forKey: previousRun); terminalPresented.remove(previousRun); executionPresented.remove(previousRun)
            }
        }
        let content = ActivityContent(state: snapshot.state, staleDate: snapshot.staleDate, relevanceScore: 100)
        if let activity = activities[run] {
            guard activity.isActive else {
                BackgroundExecutionTrace.record("activity.skipped inactive=true")
                return
            }
            await update(activity, content: content, alert: executionAlert(snapshot))
            BackgroundExecutionTrace.record("activity.updated phase=\(snapshot.state.phase) tools=\(snapshot.state.completedTools) active=\(activity.isActive)")
        } else {
            guard createActivity != nil || ActivityAuthorizationInfo().areActivitiesEnabled else {
                BackgroundExecutionTrace.record("activity.denied authorization=false")
                notice = "实时活动未开启；仍可在 App 内查看与确认"; return
            }
            do {
                let activity: any AgentActivityHandle
                if let createActivity { activity = try createActivity(snapshot) }
                else { activity = SystemAgentActivity(try Activity.request(attributes: snapshot.attributes, content: content, pushType: nil)) }
                activities[run] = activity
                BackgroundExecutionTrace.record("activity.created foreground=\(foreground) active=\(activity.isActive)")
                notice = nil
                if activity.isActive, let alert = executionAlert(snapshot) {
                    await update(activity, content: content, alert: alert)
                }
            } catch {
                // Record system error metadata only, never task text or credentials.
                let systemError = error as NSError
                BackgroundExecutionTrace.record("activity.requestFailed domain=\(systemError.domain) code=\(systemError.code) foreground=\(foreground)")
                notice = "实时活动暂不可用；仍可在 App 内查看与确认"
            }
        }
    }
}
