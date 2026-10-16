import ActivityKit
import SwiftUI
import WidgetKit
import OSLog

private let activityLogger = Logger(subsystem: "com.y175.tapito", category: "ActivityLifecycle")

/// This observes configuration evaluation, not whether the user saw the view.
private func traceActivityContext(_ context: ActivityViewContext<AgentActivityAttributes>, destination: String) {
    activityLogger.info("activity.widgetEvaluated destination=\(destination, privacy: .public) id=\(context.activityID, privacy: .public) run=\(context.attributes.runID.uuidString, privacy: .public) phase=\(context.state.phase.rawValue, privacy: .public) operation=\(context.state.operation?.rawValue ?? "none", privacy: .public) tools=\(context.state.completedTools) stale=\(context.isStale) contentTime=\(context.state.updatedAt.timeIntervalSince1970)")
}

@main struct TapitoLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        TapitoLiveActivity()
        TapitoVoiceTaskControl()
        #if DEBUG
        IslandPresentationProbeWidget()
        IslandPresentationProbeControl()
        #endif
    }
}

/// A system control binds the Action Button directly to the existing background recording intent.
struct TapitoVoiceTaskControl: ControlWidget {
    /// Stable identity used by the system's control gallery and Action Button binding.
    static let kind = "com.y175.tapito.voice-task-control"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: StartVoiceTaskIntent()) {
                Label("Tapito 语音任务", systemImage: "mic.fill")
            }
        }
        .displayName("Tapito 语音任务")
        .description("直接开始聆听，在灵动岛结束语音。")
    }
}

struct TapitoLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            let _ = traceActivityContext(context, destination: "card")
            Group {
                if context.state.phase == .standby {
                    Color.clear.frame(height: 1).accessibilityHidden(true)
                } else {
                    ActivityCard(context: context)
                }
            }
                .activityBackgroundTint(context.state.phase == .standby ? Color.clear : Color.black)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(activityURL(context))
        } dynamicIsland: { context in
            let _ = traceActivityContext(context, destination: "island")
            let standby = context.state.phase == .standby
            let stale = context.isStale && !context.state.phase.isTerminal
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if !standby {
                        Label((context.state.isDemo ?? context.attributes.isDemo) ? "\(AppIdentity.displayName) · 离线演示" : AppIdentity.displayName, systemImage: "sparkles")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    if !standby {
                        Label(stale ? "查看" : context.state.title,
                              systemImage: stale ? "exclamationmark.circle" : context.state.symbol)
                            .font(.headline).foregroundStyle(activityTint(context)).lineLimit(2)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !standby {
                        VStack(alignment: .leading, spacing: 8) {
                            if context.state.completedTools > 0 {
                                Text("本轮已处理 \(context.state.completedTools) 次操作")
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            if stale || !context.state.phase.detail.isEmpty {
                                Text(stale ? "状态已过期；执行情况需在 App 核对" : context.state.phase.detail)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            // The island has a bounded height; both controls share one row.
                            HStack(spacing: 8) {
                                VoiceEndButton(context: context)
                                Link(destination: activityURL(context)) {
                                    Label(!stale && context.state.phase == .awaitingApproval ? "查看并确认" : "查看会话", systemImage: "arrow.up.forward.app")
                                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                        .background(.white.opacity(0.12), in: Capsule())
                                }.tint(.white)
                            }
                        }
                    }
                }
            } compactLeading: {
                if !standby {
                    Image(systemName: "sparkles").foregroundStyle(.cyan)
                }
            } compactTrailing: {
                if !standby {
                    HStack(spacing: 3) {
                        if !stale && [.thinking, .voicePreparing, .pausing].contains(context.state.phase) {
                            ProgressView().controlSize(.mini).tint(.cyan)
                        } else {
                            Image(systemName: stale ? "exclamationmark.circle" : context.state.symbol)
                        }
                        Text(stale ? "查看" : context.state.compactTitle).lineLimit(1)
                    }.font(.caption2).foregroundStyle(activityTint(context))
                }
            } minimal: {
                if !standby {
                    Image(systemName: stale ? "exclamationmark.circle" : context.state.symbol).foregroundStyle(activityTint(context))
                }
            }
            .widgetURL(activityURL(context))
            .keylineTint(standby ? Color.clear : activityTint(context))
        }
    }
}

private func activityURL(_ context: ActivityViewContext<AgentActivityAttributes>) -> URL {
    context.state.route(attributes: context.attributes)?.url ?? URL(string: "tapito://home")!
}
private func activityTint(_ context: ActivityViewContext<AgentActivityAttributes>) -> Color {
    context.isStale || context.state.phase == .awaitingApproval ? .orange : .cyan
}
private struct ActivityCard: View {
    let context: ActivityViewContext<AgentActivityAttributes>
    private var stale: Bool { context.isStale && !context.state.phase.isTerminal }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label((context.state.isDemo ?? context.attributes.isDemo) ? "\(AppIdentity.displayName) · 离线演示" : AppIdentity.displayName, systemImage: "sparkles")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                Spacer()
            }
            Label(stale ? "请回到 App" : context.state.title,
                  systemImage: stale ? "exclamationmark.circle" : context.state.symbol)
                .font(.headline).foregroundStyle(activityTint(context))
            if stale || !context.state.phase.detail.isEmpty {
                Text(stale ? "状态已过期；执行情况需在 App 核对" : context.state.phase.detail)
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            HStack(spacing: 8) {
                VoiceEndButton(context: context)
                Link(destination: activityURL(context)) {
                    Label(!stale && context.state.phase == .awaitingApproval ? "查看并确认" : "查看会话", systemImage: "arrow.up.forward.app")
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(.white.opacity(0.12), in: Capsule())
                }.tint(.white)
            }
        }.foregroundStyle(.white).padding(16)
    }
}

/// A real intent button ends capture in place; the separate link still opens task details.
private struct VoiceEndButton: View {
    let context: ActivityViewContext<AgentActivityAttributes>
    var body: some View {
        if let id = context.state.activeVoiceSessionID(attributes: context.attributes) {
            Button(intent: EndVoiceSessionIntent(sessionID: id)) {
                Label("结束语音", systemImage: "stop.circle.fill")
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(.red.opacity(0.28), in: Capsule())
            }
            .buttonStyle(.plain).foregroundStyle(.red)
            .accessibilityIdentifier("tapito.voice.endActivity")
        }
    }
}
