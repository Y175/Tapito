import SwiftUI

/// Shared visual tokens; execution code depends on neither SwiftUI nor this palette.
enum TapitoPalette {
    static let accent = Color(red: 0.65, green: 0.59, blue: 1)
    static let ink = Color(red: 0.065, green: 0.065, blue: 0.09)
    static let panel = Color(red: 0.10, green: 0.10, blue: 0.14)
}

/// App-owned animation may repeat. Live Activities only animate real data updates,
/// within WidgetKit's two-second budget; no timer or synthetic progress is submitted.
struct AgentActivityIndicator: View {
    enum Surface { case app, liveActivity }
    let presentation: AgentActivityPresentation
    var surface: Surface = .app
    var size: CGFloat = 26
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var dimmed
    @State private var rotating = false

    private var tint: Color {
        presentation.needsAttention ? .orange : presentation.state.phase == .completed ? .mint : TapitoPalette.accent
    }
    var body: some View {
        Group {
            if presentation.isBusy {
                if surface == .liveActivity {
                    Image(systemName: "progress.indicator")
                        .font(.system(size: size * 0.8, weight: .semibold))
                        .symbolEffect(.rotate, options: .nonRepeating,
                                      value: reduceMotion || dimmed ? "static" : presentation.animationKey)
                } else {
                    ZStack {
                        Circle().stroke(tint.opacity(0.18), lineWidth: 2.5)
                        Circle().trim(from: 0.06, to: 0.76)
                            .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(rotating && !reduceMotion ? 360 : 0))
                            .animation(reduceMotion ? nil : .linear(duration: 1.1).repeatForever(autoreverses: false), value: rotating)
                        Circle().fill(tint).frame(width: 4, height: 4)
                    }.onAppear { rotating = true }.onDisappear { rotating = false }
                }
            } else {
                Image(systemName: presentation.symbol).font(.system(size: size * 0.85, weight: .medium))
            }
        }
        .foregroundStyle(tint).frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Highlights only the current stage. Earlier stages aren't marked successful:
/// the agent can observe, act and verify repeatedly or skip a stage entirely.
struct AgentStepStrip: View {
    let active: AgentActivityAttributes.Step
    private let stages: [AgentActivityAttributes.Step] = [.planning, .observing, .acting, .verifying]
    private var selected: AgentActivityAttributes.Step {
        active == .correcting ? .planning : active
    }
    var body: some View {
        HStack(spacing: 5) {
            ForEach(stages, id: \.self) { stage in
                Text(stage == .planning && active == .correcting ? "纠错" : stage.title)
                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(selected == stage ? TapitoPalette.accent : Color.white.opacity(0.48))
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background(selected == stage ? TapitoPalette.accent.opacity(0.16) : Color.white.opacity(0.04), in: Capsule())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("当前阶段：\(active.title)")
    }
}

/// Compact, privacy-safe task summary used inside the app and on the Lock Screen.
struct AgentProgressSummary: View {
    let presentation: AgentActivityPresentation
    var surface: AgentActivityIndicator.Surface = .app
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AgentActivityIndicator(presentation: presentation, surface: surface, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        .contentTransition(.interpolate)
                    Text(presentation.detail).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
                }
                Spacer(minLength: 0)
                if let step = presentation.step {
                    Text(step.title).font(.caption2.weight(.semibold)).foregroundStyle(TapitoPalette.accent)
                }
            }
            if let step = presentation.step { AgentStepStrip(active: step) }
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}
