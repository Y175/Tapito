#if DEBUG && targetEnvironment(simulator)
import Foundation
import TapitoVoiceCore

/// Explicit simulator-only input for testing the real recording intent/controller and system UI.
/// It never opens the microphone, contacts a provider, or controls a physical device.
@MainActor final class SimulatorVoiceFixture: VoiceAudio {
    private static let key = "tapito.simulatorVoiceFixture"
    /// Persist only in the simulator so a system-launched cold intent uses the same fixture.
    static var enabled: Bool {
        if ProcessInfo.processInfo.environment["TAPITO_ISOLATED_TESTS"] == "1" { return false }
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--tapito-simulator-voice") { UserDefaults.standard.set(true, forKey: key) }
        if args.contains("--tapito-simulator-voice-off") { UserDefaults.standard.removeObject(forKey: key) }
        return UserDefaults.standard.bool(forKey: key)
    }
    private var events: (@MainActor (VoiceAudioEvent) -> Void)?

    static func makeModel() -> AgentSessionController {
        let providers = ProviderStore(defaults: nil)
        let profile = ProviderProfile(name: "Simulator voice fixture", settings: .init(baseURL: "https://fixture.invalid/v1", model: "offline"))
        do { try providers.save(profile); try providers.setDefaultProvider(profile.id) }
        catch { preconditionFailure("Invalid simulator fixture: \(error)") }
        return AgentSessionController(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
            runServices: .init(execution: .reactFixture, provider: DemoProvider(), bridge: DemoBridge()),
            liveActivitiesEnabled: true, providers: providers)
    }

    func prepare() async throws { BackgroundExecutionTrace.record("voice.fixture prepare synthetic=true") }
    func start(events: @escaping @MainActor (VoiceAudioEvent) -> Void) async throws {
        self.events = events
        events(.captureActive(true))
        BackgroundExecutionTrace.record("voice.fixture captureStarted synthetic=true")
    }
    func preparePlayback(events: @escaping @MainActor (VoiceAudioEvent) -> Void) async throws {
        throw AppError.invalid("模拟器展示验证不支持执行语音任务")
    }
    func stop() throws {
        events?(.captureActive(false)); events = nil
        BackgroundExecutionTrace.record("voice.fixture captureStopped synthetic=true")
    }
    func speak(_ text: String) throws -> UUID {
        // The visual fixture supplies no utterances; unexpected task execution must fail visibly.
        throw AppError.invalid("模拟器展示验证不支持执行语音任务")
    }
    func stopSpeaking() {}
}
#endif
