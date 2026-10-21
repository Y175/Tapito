import SwiftUI

/// Only the running label ticks. Completed intervals come from persisted monotonic measurements.
struct StepDurationLabel: View {
    let timing: StepTiming?
    let running: Bool
    var body: some View {
        Group {
            if let seconds = timing?.durationSeconds {
                Text(Self.duration(seconds))
            } else if running, let timing {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("已等待 " + Self.duration(max(0, context.date.timeIntervalSince(timing.startedAt))))
                }
            } else { Text(running ? "计时未开始" : "耗时未记录") }
        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
    }
    private static func duration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? String(format: "%.0f 毫秒", seconds * 1_000) : String(format: "%.2f 秒", seconds)
    }
}

/// Model requests remain visible even when their response consists only of tool calls.
struct ModelRequestStepView: View {
    let message: ChatMessage
    var body: some View {
        HStack(spacing: 8) {
            MessageHeaderIcon(systemName: "sparkles")
            if let turn = message.modelTurn { Text("模型请求 \(turn)") }
            Spacer(minLength: 8)
            StepDurationLabel(timing: message.timing, running: message.state == .streaming)
            if message.state == .streaming { Text("等待模型").font(.caption) }
            if message.state == .interrupted { Text("已中止").font(.caption) }
            if message.state == .failed { Text("失败").font(.caption).foregroundStyle(.red) }
        }.foregroundStyle(.secondary).accessibilityIdentifier("modelRequestStep")
    }
}
