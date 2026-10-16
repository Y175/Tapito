#if DEBUG
@preconcurrency import ActivityKit
import AppIntents
import Foundation
#if TAPITO_APP
import UIKit
import SwiftUI
#endif

/// Temporary device diagnostic: independent of voice, task progress and their activity payloads.
struct IslandPresentationProbeAttributes: ActivityAttributes {
    /// Exact identity prevents a stale close button from ending a later probe.
    let probeID: UUID
    struct ContentState: Codable, Hashable {
        let startedAt: Date
    }
}

/// Requests exactly one transient surface from the same system control entry point as voice.
struct StartIslandPresentationProbeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Tapito 展开验证"
    static var isDiscoverable: Bool { false }
    static var openAppWhenRun: Bool { false }
    static var supportedModes: IntentModes { .background }
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @available(iOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @MainActor func perform() async throws -> some IntentResult {
        #if TAPITO_APP
        try Task.checkCancellation()
        try IslandPresentationProbe.start()
        #else
        throw NSError(domain: "Tapito.IslandProbe", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "展开验证未进入主 App 进程"])
        #endif
        return .result()
    }
}

/// Closes only the diagnostic activity; it never touches a voice session or device task.
struct EndIslandPresentationProbeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "关闭展开验证"
    static var isDiscoverable: Bool { false }
    static var openAppWhenRun: Bool { false }
    static var supportedModes: IntentModes { .background }
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @available(iOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Probe identity") var probeID: String
    init() {}
    init(probeID: UUID) { self.probeID = probeID.uuidString }

    @MainActor func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: probeID) else {
            throw NSError(domain: "Tapito.IslandProbe", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "展开验证标识无效"])
        }
        #if TAPITO_APP
        guard let activity = Activity<IslandPresentationProbeAttributes>.activities.first(where: { $0.attributes.probeID == id }) else {
            throw NSError(domain: "Tapito.IslandProbe", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "这次展开验证已经结束"])
        }
        await activity.end(nil, dismissalPolicy: .immediate)
        BackgroundExecutionTrace.record("islandProbe.end id=\(id)")
        #else
        throw NSError(domain: "Tapito.IslandProbe", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "展开验证未进入主 App 进程"])
        #endif
        return .result()
    }
}

#if TAPITO_APP
/// Explicit launch-argument surface for inspecting ActivityKit rendering without a microphone.
struct IslandPresentationProbeView: View {
    @State private var result = "仅验证灵动岛展示，不录音、不执行任务。"

    var body: some View {
        VStack(spacing: 24) {
            Text("Tapito 展开验证").font(.title)
            Text(result).accessibilityIdentifier("islandProbe.result")
            Button("创建单个临时活动") {
                Task { @MainActor in
                    do {
                        _ = try await StartIslandPresentationProbeIntent().perform()
                        result = "请求已成功；请以灵动岛实际显示为准。"
                    } catch {
                        result = error.localizedDescription
                    }
                }
            }.accessibilityIdentifier("islandProbe.start")
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

@MainActor private enum IslandPresentationProbe {
    /// Retains observation without keeping the intent open or scheduling presentation updates.
    private static var observation: Task<Void, Never>?

    static func start() throws {
        let runningTasks = Activity<AgentActivityAttributes>.activities.filter {
            $0.activityState == .active || $0.activityState == .stale
        }
        let runningProbes = Activity<IslandPresentationProbeAttributes>.activities.filter {
            $0.activityState == .active || $0.activityState == .stale
        }
        // A competing Tapito activity invalidates this experiment; never stop the user's task for it.
        guard runningTasks.isEmpty, runningProbes.isEmpty else {
            throw NSError(domain: "Tapito.IslandProbe", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "请先结束 Tapito 的语音、任务及上一次展开验证，再运行此测试"])
        }
        let id = UUID()
        BackgroundExecutionTrace.record("islandProbe.entry id=\(id) foreground=\(UIApplication.shared.applicationState == .active)")
        do {
            let activity = try Activity.request(attributes: IslandPresentationProbeAttributes(probeID: id),
                content: ActivityContent(state: IslandPresentationProbeAttributes.ContentState(startedAt: Date()), staleDate: nil),
                pushType: nil, style: .transient)
            BackgroundExecutionTrace.record("islandProbe.created id=\(id) activity=\(activity.id) state=\(activity.activityState)")
            observation?.cancel()
            observation = Task {
                for await state in activity.activityStateUpdates {
                    guard !Task.isCancelled else { return }
                    BackgroundExecutionTrace.record("islandProbe.state id=\(id) state=\(state)")
                    if state == .ended || state == .dismissed { return }
                }
            }
        } catch {
            let failure = error as NSError
            BackgroundExecutionTrace.record("islandProbe.failed id=\(id) domain=\(failure.domain) code=\(failure.code)")
            throw error
        }
    }
}
#endif
#endif
