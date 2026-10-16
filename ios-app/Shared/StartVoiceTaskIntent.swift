import AppIntents
import Foundation
#if TAPITO_APP
import UIKit
#endif

/// A parameter-free Action Button entry; permission setup happens in the app beforehand.
struct StartVoiceTaskIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Start voice task"
    static let description = IntentDescription("Listen for a voice task without opening Tapito. End recording from the Live Activity.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static var openAppWhenRun: Bool { false }
    static var supportedModes: IntentModes { .background }
    @available(iOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @MainActor func perform() async throws -> some IntentResult {
        #if TAPITO_APP
        let enteredAt = ProcessInfo.processInfo.systemUptime
        // Entry timing includes lazy runtime/audio construction, unlike the controller's start event.
        BackgroundExecutionTrace.record("voice.intentEntry foreground=\(UIApplication.shared.applicationState == .active)")
        try Task.checkCancellation()
        let voice = TapitoRuntime.shared.voice
        BackgroundExecutionTrace.record("voice.runtimeReady elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - enteredAt) * 1000))")
        try await voice.startFromRecordingIntent()
        BackgroundExecutionTrace.record("voice.intentStarted policy=location elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - enteredAt) * 1000))")
        #else
        // Control metadata lives in the extension; recording must run in the main app process.
        throw NSError(domain: "Tapito.VoiceIntent", code: 3,
            userInfo: [NSLocalizedDescriptionKey: "系统未将语音启动交给 Tapito，请重新选择 Tapito 语音任务控制"])
        #endif
        return .result()
    }
}
