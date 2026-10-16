import AppIntents
import UIKit

struct PrepareAgentTaskIntent: LiveActivityIntent, TargetContentProvidingIntent {
    var contentIdentifier: String { "execute-task" }
    static let title: LocalizedStringResource = "Execute a task"
    static let description = IntentDescription("Execute a task with your selected model. Continuous voice keeps listening until you end the conversation.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static var openAppWhenRun: Bool { false }
    @available(iOS 26.0, *) static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
    @available(iOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Task", requestValueDialog: "What would you like Tapito to do?")
    var task: String
    @Parameter(title: "Continuous voice conversation", default: true)
    var continuousConversation: Bool

    static var parameterSummary: some ParameterSummary { Summary("Execute a task: \(\.$task)") }

    @MainActor func perform() async throws -> some IntentResult {
        try Task.checkCancellation()
        let runtime = TapitoRuntime.shared
        runtime.model.setProtectedDataAvailable(UIApplication.shared.isProtectedDataAvailable)
        let needsForeground = runtime.model.commandNeedsForeground || (continuousConversation && !runtime.voice.session.state.phase.isActive)
        runtime.model.usbDiagnostics.record("siri.execute handoffRequired=\(needsForeground) mediaActive=\(PiPExecutionActivity.shared.active)")
        if needsForeground {
            try await continueInForeground(alwaysConfirm: false)
            try Task.checkCancellation()
        }
        if continuousConversation {
            try await runtime.voice.execute(task)
            await runtime.model.liveActivities.waitForPendingUpdates()
            return .result()
        }
        let service = runtime.commands
        TapitoRuntime.shared.model.usbDiagnostics.record("siri.execute received=true ready=\(TapitoRuntime.shared.model.commandCanStart)")
        let command = SessionCommand(.execute(task))
        do {
            try await submit(command, using: service, activities: runtime.model.liveActivities)
        } catch {
            let model = TapitoRuntime.shared.model
            model.errorMessage = error.localizedDescription
            model.usbDiagnostics.record("siri.execute failed=\(error.localizedDescription)")
            if let session = service.sessions.conversations.first(where: { $0.entry?.commandID == command.commandID }) {
                service.sessions.addNotice(error.localizedDescription, in: session.id)
            }
        }
        return .result()
    }

    @MainActor func submit(_ command: SessionCommand, using service: SessionCommandService,
                           activities: AgentLiveActivityController) async throws {
        if case .started = try service.perform(command) {
            // send() queues the initial activity synchronously. Keep the
            // LiveActivityIntent scope alive until that request has returned;
            // do not wait for the model run or retry a rejected activity request.
            await activities.waitForPendingUpdates()
        }
    }
}

struct AgentTaskStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Check task status"
    static let description = IntentDescription("Read only a general task state, without task text or results.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .background }
    @available(iOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try Task.checkCancellation()
        let voice = TapitoRuntime.shared.voice.session.state
        if voice.phase.isActive {
            let message: String
            switch voice.phase {
            case .preparing: message = "正在准备语音"
            case .listening: message = "正在聆听下一句"
            case .executing: message = "正在执行语音任务"
            case .interrupting: message = "正在停止后续操作"
            case .speaking: message = "正在播报"
            case .paused: message = "语音已暂停"
            case .idle, .ended, .failed: throw AppError.invalid("语音状态已改变，请重新查询")
            }
            return .result(dialog: IntentDialog(stringLiteral: message))
        }
        guard case .status(let status) = try TapitoRuntime.shared.commands.perform(SessionCommand(.status)) else {
            return .result(dialog: "No task is currently running.")
        }
        return .result(dialog: IntentDialog(stringLiteral: status.message))
    }
}

struct StopAgentTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop the current task"
    static let description = IntentDescription("Stop the current run through Tapito. Actions already sent may have happened.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .background }
    @available(iOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try Task.checkCancellation()
        if TapitoRuntime.shared.voice.session.state.phase.isActive {
            TapitoRuntime.shared.voice.session.end()
            if let error = TapitoRuntime.shared.voice.session.state.error { throw AppError.unavailable(error) }
            return .result(dialog: "Voice conversation ended. Actions already sent may have happened; check your device.")
        }
        let service = TapitoRuntime.shared.commands
        let command = service.cancelCurrentCommand()
        if try service.perform(command) == .cancelled {
            return .result(dialog: "Stop requested. Actions already sent may have happened; check your device.")
        }
        return .result(dialog: "No matching task is currently running.")
    }
}

struct TapitoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartVoiceTaskIntent(), phrases: ["Start a voice task in \(.applicationName)"],
                    shortTitle: "Start voice task", systemImageName: "mic.fill")
        AppShortcut(intent: PrepareAgentTaskIntent(), phrases: ["Execute a task with \(.applicationName)", "Execute a task in \(.applicationName)"],
                    shortTitle: "Execute a task", systemImageName: "square.and.pencil")
        AppShortcut(intent: AgentTaskStatusIntent(), phrases: ["Check task status in \(.applicationName)"],
                    shortTitle: "Task status", systemImageName: "checklist")
        AppShortcut(intent: StopAgentTaskIntent(), phrases: ["Stop the current task in \(.applicationName)"],
                    shortTitle: "Stop task", systemImageName: "stop.circle")
    }
}
