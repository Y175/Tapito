import AppIntents
import Foundation

/// Shared metadata lets the widget invoke the main app's exact-session stop action.
struct EndVoiceSessionIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "End voice conversation"
    static var isDiscoverable: Bool { false }
    static var openAppWhenRun: Bool { false }
    static var supportedModes: IntentModes { .background }
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @available(iOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }

    /// Binds an old island/card to its own session, never whichever session runs later.
    @Parameter(title: "Voice session") var voiceSessionID: String

    init() {}
    init(sessionID: UUID) { voiceSessionID = sessionID.uuidString }

    @MainActor func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: voiceSessionID) else {
            throw NSError(domain: "Tapito.VoiceIntent", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "语音会话标识无效，未执行结束操作"])
        }
        #if TAPITO_APP
        let runtime = TapitoRuntime.shared
        try runtime.voice.session.end(sessionID: id)
        BackgroundExecutionTrace.record("voice.intentEnd matched=true")
        await runtime.model.liveActivities.waitForPendingUpdates()
        #else
        // LiveActivityIntent must execute in the app process, never a widget-local imitation.
        throw NSError(domain: "Tapito.VoiceIntent", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "系统未将结束操作交给 Tapito，请在 App 中结束语音"])
        #endif
        return .result()
    }
}
