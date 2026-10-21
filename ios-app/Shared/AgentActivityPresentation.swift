import Foundation

/// Safe, deterministic projection shared by conversation cards and system surfaces.
/// Stale/terminal/approval state always outranks the last operation or model node.
struct AgentActivityPresentation {
    let state: AgentActivityAttributes.ContentState
    var isStale = false

    var needsAttention: Bool {
        stale || [.awaitingApproval, .blocked, .interrupted, .paused].contains(state.phase)
    }
    var stale: Bool { isStale && !state.phase.isTerminal }
    var isBusy: Bool {
        !stale && [.thinking, .working, .executing, .voicePreparing, .pausing].contains(state.phase)
    }
    var step: AgentActivityAttributes.Step? {
        guard !stale, [.thinking, .working, .executing].contains(state.phase) else { return nil }
        return state.step ?? state.operation?.step
    }
    var compactTitle: String { stale ? "查看" : step?.title ?? state.compactTitle }
    var title: String {
        if stale { return "状态待核对" }
        guard [.thinking, .working, .executing].contains(state.phase) else { return state.phase.title }
        if let operation = state.operation, operation != .processing { return operation.title }
        return step?.detail ?? state.title
    }
    var symbol: String {
        if stale { return "exclamationmark.circle" }
        guard [.thinking, .working, .executing].contains(state.phase) else { return state.phase.symbol }
        return state.symbol
    }
    var detail: String {
        if stale { return "状态已过期，请查看会话" }
        switch state.phase {
        case .thinking, .working, .executing:
            return state.completedTools == 0 ? "正在处理当前任务" : "已处理 \(state.completedTools) 项工具调用"
        case .completed: return "查看会话中的结果"
        case .listening: return "说出任务，或点击结束"
        case .voicePreparing: return "麦克风准备中"
        case .speaking: return "播报结束后继续聆听"
        default: return state.phase.detail
        }
    }
    /// Stable on heartbeats: animation changes only on meaningful state transitions.
    var animationKey: String {
        "\(state.phase.rawValue):\(state.step?.rawValue ?? ""):\(state.operation?.rawValue ?? ""):\(state.completedTools):\(stale)"
    }
}
