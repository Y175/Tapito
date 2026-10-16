import Foundation

/// Device-independent page evidence. Pixel samples are generated locally, never sent to a model.
public struct WorkflowPage: Codable, Equatable, Sendable {
    /// Exact physical screenshot geometry; rotation or a different device requires new training.
    public let width: Int
    public let height: Int
    /// Versioned 24 x 48 RGB sampling of the area below the status bar and above the home indicator.
    public let pixels: Data
    public init(width: Int, height: Int, pixels: Data) {
        self.width = width; self.height = height; self.pixels = pixels
    }
    public func validate() throws {
        guard (100...10000).contains(width), (100...10000).contains(height), pixels.count == 24 * 48 * 3 else {
            throw AssistantError.invalid("流程页面特征或屏幕尺寸无效。")
        }
    }
    /// Conservative visual equality, not semantic proof that a particular control exists.
    public func matches(_ other: Self) throws -> Bool {
        try validate(); try other.validate()
        guard width == other.width, height == other.height else { return false }
        let differences = zip(pixels, other.pixels).map { abs(Int($0) - Int($1)) }
        return differences.max()! <= 28 && differences.reduce(0, +) <= differences.count * 3
    }
}

/// A deliberately finite instruction set. Scripts, arbitrary tool names and automatic retries are excluded.
public enum WorkflowAction: Codable, Equatable, Sendable {
    case tap(x: Int, y: Int)
    case drag(x: Int, y: Int, toX: Int, toY: Int, milliseconds: Int)
    case insert(argument: String)
    case wait(milliseconds: Int)
}

/// One learned operation with its actual pre-action screen, purpose and delivery evidence.
public struct WorkflowStep: Codable, Equatable, Sendable {
    public let action: WorkflowAction
    /// Nil is valid only for waits. Inputs always require a fresh page comparison at replay time.
    public let page: WorkflowPage?
    /// Compact local patch around a tap/drag start, in 16 x 16 RGB bytes; checks the stored target too.
    public let targetPatch: Data?
    /// Public button meaning / input field description, not private model reasoning.
    public let purpose: String
    public init(action: WorkflowAction, page: WorkflowPage?, targetPatch: Data? = nil, purpose: String) {
        self.action = action; self.page = page; self.targetPatch = targetPatch; self.purpose = purpose
    }
    public func validate() throws {
        guard !purpose.isEmpty, purpose.count <= 160 else { throw AssistantError.invalid("流程步骤用途缺失或过长。") }
        if case .wait(let milliseconds) = action {
            guard (1...3000).contains(milliseconds), page == nil, targetPatch == nil else { throw AssistantError.invalid("流程等待参数无效。") }
            return
        }
        guard let page else { throw AssistantError.invalid("输入前没有新的页面证据，不能沉淀为坐标流程；请先观察再操作。") }
        try page.validate()
        func point(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < page.width && y < page.height }
        switch action {
        case .tap(let x, let y):
            guard point(x, y), targetPatch?.count == 16 * 16 * 3 else { throw AssistantError.invalid("按钮坐标或目标区域证据无效。") }
        case .drag(let x, let y, let tx, let ty, let milliseconds):
            guard point(x, y), point(tx, ty), (100...2000).contains(milliseconds), targetPatch?.count == 16 * 16 * 3 else { throw AssistantError.invalid("拖动参数或目标区域证据无效。") }
        case .insert(let key):
            guard key.hasPrefix("text_"), Int(key.dropFirst(5)).map({ $0 > 0 && $0 <= 32 }) == true, targetPatch == nil else { throw AssistantError.invalid("输入参数引用无效。") }
        case .wait: break
        }
    }
}

/// A host-recorded, acknowledged sequence; no original typed text or screenshot is persisted.
public struct WorkflowTrace: Codable, Sendable {
    public let runID: UUID
    /// Stable workflow name supplied by the planner, or a host-generated application label.
    public let name: String
    public let appBundleID: String
    public let appVersion: String
    public let systemVersion: String
    public let steps: [WorkflowStep]
    /// An observation obtained after the last dispatched input, not a model success claim.
    public let finalPage: WorkflowPage
    public init(runID: UUID, name: String, appBundleID: String, appVersion: String, systemVersion: String,
                steps: [WorkflowStep], finalPage: WorkflowPage) {
        self.runID = runID; self.name = name; self.appBundleID = appBundleID; self.appVersion = appVersion
        self.systemVersion = systemVersion; self.steps = steps; self.finalPage = finalPage
    }
    public func validate() throws {
        guard !name.isEmpty, name.count <= 100, !appBundleID.isEmpty, appBundleID.count <= 256,
              !appVersion.isEmpty, appVersion.count <= 100, !systemVersion.isEmpty, systemVersion.count <= 200,
              (1...32).contains(steps.count), steps.contains(where: { if case .wait = $0.action { return false }; return true }) else {
            throw AssistantError.invalid("流程名称、版本或步骤数量无效。")
        }
        try finalPage.validate()
        for step in steps {
            try step.validate()
            if let page = step.page, page.width != finalPage.width || page.height != finalPage.height {
                throw AssistantError.invalid("流程中屏幕方向或尺寸发生变化，需要拆分训练。")
            }
        }
        let keys = argumentKeys
        guard keys == (1...max(keys.count, 1)).prefix(keys.count).map({ "text_\($0)" }) else {
            throw AssistantError.invalid("流程文本参数必须按操作顺序编号且不能重复。")
        }
    }
    public var argumentKeys: [String] {
        steps.compactMap { if case .insert(let key) = $0.action { return key }; return nil }
    }
}

/// Published revisions are immutable; a new training run produces a separate review candidate.
public struct LearnedWorkflow: Codable, Identifiable, Sendable {
    public let id: UUID
    public let revision: UUID
    public let trace: WorkflowTrace
    /// candidate / active / disabled / stale. Only a user review can activate a candidate.
    public var state: String
    public var successfulReplays: Int
    public var lastFailure: String?
    public let createdAt: Date
}

/// Host adapter owns screenshots, platform permissions, durable input receipts and cancellation fences.
public protocol WorkflowDevice: Sendable {
    func workflowVersion(app: String) async throws -> String
    func workflowLaunch(app: String, callID: String) async throws
    /// Compare fresh local pixels and dispatch through the same authorization path as ordinary tools.
    func workflowPerform(step: WorkflowStep, text: String?, callID: String) async throws
    func workflowVerify(page: WorkflowPage, callID: String) async throws
}

/// Typed preflight failures distinguish layout drift from unknown or failed input delivery.
public enum WorkflowMismatch: Error, LocalizedError {
    case version, page
    public var errorDescription: String? {
        switch self {
        case .version: return "流程的 App/iOS 版本已变化；未继续执行，请重新观察并训练。"
        case .page: return "流程页面或按钮区域已变化；本步未发送，后续已停止。请重新观察并纠正流程；不要重放之前步骤。"
        }
    }
}

/// Runs a fully validated, parameter-bound plan locally with no model/OCR request between steps.
public enum WorkflowExecutor {
    public static func run(_ workflow: LearnedWorkflow, arguments: [String: String], systemVersion: String,
                           callID: String, device: any WorkflowDevice,
                           permit: @Sendable () async throws -> Void) async throws {
        try workflow.trace.validate()
        guard workflow.state == "active", Set(arguments.keys) == Set(workflow.trace.argumentKeys),
              arguments.values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8192 && !$0.utf8.contains(0) }) else {
            throw AssistantError.invalid("流程未启用或输入参数不完整；尚未操作设备。")
        }
        try await permit(); try Task.checkCancellation()
        guard workflow.trace.systemVersion == systemVersion,
              try await device.workflowVersion(app: workflow.trace.appBundleID) == workflow.trace.appVersion else { throw WorkflowMismatch.version }
        try await permit(); try Task.checkCancellation()
        try await device.workflowLaunch(app: workflow.trace.appBundleID, callID: callID + ".launch")
        for (index, step) in workflow.trace.steps.enumerated() {
            try await permit(); try Task.checkCancellation()
            let text: String?
            if case .insert(let key) = step.action { text = arguments[key] } else { text = nil }
            // A thrown dispatch is never retried, even if its result is unknown.
            try await device.workflowPerform(step: step, text: text, callID: callID + ".step.\(index)")
        }
        try await permit(); try Task.checkCancellation()
        try await device.workflowVerify(page: workflow.trace.finalPage, callID: callID + ".verify")
        try await permit(); try Task.checkCancellation()
    }
}
