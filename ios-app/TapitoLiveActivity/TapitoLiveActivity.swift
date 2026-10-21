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

/// Expanded content stays in one bottom region to avoid clipping controls around the sensor.
struct TapitoLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            let _ = traceActivityContext(context, destination: "card")
            Group {
                if context.state.phase == .standby {
                    Color.clear.frame(height: 1).accessibilityHidden(true)
                } else { ActivityCard(context: context) }
            }
            .activityBackgroundTint(context.state.phase == .standby ? Color.clear : TapitoPalette.ink)
            .activitySystemActionForegroundColor(.white)
            .widgetURL(activityURL(context))
        } dynamicIsland: { context in
            let _ = traceActivityContext(context, destination: "island")
            let standby = context.state.phase == .standby
            let presentation = AgentActivityPresentation(state: context.state, isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if !standby {
                        HStack(spacing: 6) {
                            AgentActivityIndicator(presentation: presentation, surface: .liveActivity, size: 19)
                            Text((context.state.isDemo ?? context.attributes.isDemo) ? "Tapito · 演示" : "Tapito")
                                .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !standby {
                        Text(presentation.compactTitle).font(.caption.weight(.semibold))
                            .foregroundStyle(presentation.needsAttention ? .orange : TapitoPalette.accent)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !standby {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(presentation.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Spacer(minLength: 6)
                                if context.state.completedTools > 0 {
                                    Text("\(context.state.completedTools) 项").font(.caption.monospacedDigit())
                                        .foregroundStyle(.white.opacity(0.5))
                                        .accessibilityLabel("已处理 \(context.state.completedTools) 项工具调用")
                                }
                            }
                            if let step = presentation.step { AgentStepStrip(active: step) }
                            ActivityActions(context: context)
                        }.foregroundStyle(.white).padding(.top, 3)
                    }
                }
            } compactLeading: {
                if !standby { AgentActivityIndicator(presentation: presentation, surface: .liveActivity, size: 19) }
            } compactTrailing: {
                if !standby {
                    Text(presentation.compactTitle).font(.caption2.weight(.semibold))
                        .foregroundStyle(presentation.needsAttention ? .orange : TapitoPalette.accent)
                }
            } minimal: {
                if !standby { AgentActivityIndicator(presentation: presentation, surface: .liveActivity, size: 18) }
            }
            .widgetURL(activityURL(context))
            .keylineTint(standby ? .clear : presentation.needsAttention ? .orange : TapitoPalette.accent)
        }
    }
}

private func activityURL(_ context: ActivityViewContext<AgentActivityAttributes>) -> URL {
    context.state.route(attributes: context.attributes)?.url ?? URL(string: "tapito://home")!
}

private struct ActivityCard: View {
    let context: ActivityViewContext<AgentActivityAttributes>
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("TAPITO").font(.caption2.weight(.bold)).tracking(2)
                Spacer()
                if context.state.isDemo ?? context.attributes.isDemo { Text("离线演示").font(.caption2) }
            }.foregroundStyle(.white.opacity(0.5))
            AgentProgressSummary(presentation: .init(state: context.state, isStale: context.isStale), surface: .liveActivity)
            ActivityActions(context: context)
        }.padding(16)
    }
}

/// Stop is always scoped to the identity on this card. Approval still requires the app's evidence view.
private struct ActivityActions: View {
    let context: ActivityViewContext<AgentActivityAttributes>
    var body: some View {
        HStack(spacing: 8) {
            if let voiceID = context.state.activeVoiceSessionID(attributes: context.attributes) {
                Button(intent: EndVoiceSessionIntent(sessionID: voiceID)) {
                    actionLabel("结束语音", symbol: "stop.fill", destructive: true)
                }
                .buttonStyle(.plain).accessibilityIdentifier("tapito.voice.endActivity")
            } else if !context.state.phase.isTerminal, context.state.phase != .standby,
                      let route = context.state.route(attributes: context.attributes) {
                Button(intent: StopActivityTaskIntent(sessionID: route.sessionID, runID: route.runID)) {
                    actionLabel("停止任务", symbol: "stop.fill", destructive: true)
                }
                .buttonStyle(.plain).accessibilityIdentifier("tapito.task.stopActivity")
            }
            Link(destination: activityURL(context)) {
                actionLabel(context.state.phase == .awaitingApproval ? "查看并确认" : "查看会话",
                            symbol: "arrow.up.right", destructive: false)
            }
        }
    }
    private func actionLabel(_ title: String, symbol: String, destructive: Bool) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(destructive ? Color(red: 1, green: 0.48, blue: 0.52) : .white)
            .background(destructive ? Color.red.opacity(0.18) : Color.white.opacity(0.10), in: Capsule())
    }
}
