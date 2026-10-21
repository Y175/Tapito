import AppIntents
import Foundation

/// Stops only the task represented by this card; an obsolete card cannot stop a new run.
struct StopActivityTaskIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "停止当前任务"
    static var isDiscoverable: Bool { false }
    static var openAppWhenRun: Bool { false }
    static var supportedModes: IntentModes { .background }
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @available(iOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }

    /// Exact conversation and run identity, never tool arguments or approval authority.
    @Parameter(title: "Conversation") var conversationID: String
    @Parameter(title: "Run") var runID: String
    init() {}
    init(sessionID: UUID, runID: UUID) {
        conversationID = sessionID.uuidString; self.runID = runID.uuidString
    }
    @MainActor func perform() async throws -> some IntentResult {
        guard let conversation = UUID(uuidString: conversationID), let run = UUID(uuidString: runID) else {
            throw NSError(domain: "Tapito.TaskIntent", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "任务标识无效，未执行停止操作"])
        }
        #if TAPITO_APP
        let model = TapitoRuntime.shared.model
        guard model.stop(run: RunIdentity(conversationID: conversation, runID: run)) else {
            throw AppError.unavailable("这条任务已结束或已改变，未停止其他任务")
        }
        await model.liveActivities.waitForPendingUpdates()
        #else
        throw NSError(domain: "Tapito.TaskIntent", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "系统未将停止请求交给 Tapito，请在会话内停止"])
        #endif
        return .result()
    }
}
