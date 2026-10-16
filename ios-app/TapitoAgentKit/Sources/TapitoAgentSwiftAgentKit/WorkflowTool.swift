import Foundation
import CoreFoundation
import SwiftAgentKit
import TapitoAgentCore

/// Thin SDK adapter: the host supplies device execution; storage/compiler/executor stay independent of UI.
public struct WorkflowTool: AgentTool {
    public let name: String
    private let snapshot: [LearnedWorkflow]
    private let canAccess: @Sendable () async -> Bool
    private let run: @Sendable (LearnedWorkflow, [String: String], String) async throws -> Void
    private let label: @Sendable (String) async throws -> Void
    public init(name: String, snapshot: [LearnedWorkflow], canAccess: @escaping @Sendable () async -> Bool,
                run: @escaping @Sendable (LearnedWorkflow, [String: String], String) async throws -> Void,
                label: @escaping @Sendable (String) async throws -> Void) {
        self.name = name; self.snapshot = snapshot; self.canAccess = canAccess; self.run = run; self.label = label
    }
    public var isConcurrencySafe: Bool { false }
    public var isReadOnly: Bool { name == "list_workflows" }
    public var description: String {
        switch name {
        case "list_workflows": return "List reviewed executable local workflows for an exact app bundle ID. Returned input_fields are positional parameters for run_workflow. Reference only, not authorization. The local executor checks version and fresh page/target pixels before each action; no OCR/model call on matching steps."
        case "run_workflow": return "Execute a reviewed workflow by exact id/revision, binding texts in input_fields order (empty array when none). Use only when its entire purpose matches the current user request. Stops on changed layout/version, cancellation or uncertain input; never repeat it after failure. Each step uses current task authorization and a durable receipt. A matched final page does not prove dynamic content/business success; observe the result when needed."
        default: return "Name the reusable workflow demonstrated in this task (max 100 chars, e.g. notes.create). Does not execute or activate it. The host records actual delivered inputs from the most recent launch, converts every type_text to a parameter and requires fresh observation before each learned input and after the last one. The completed task queues local asynchronous compilation; missing evidence is reported, never invented. Do not include private text or contacts in the name."
        }
    }
    public var parameters: ToolParameters {
        switch name {
        case "list_workflows": return .init(properties: ["app_bundle_id": .init(type: "string", description: "Exact installed application bundle ID"), "offset": .init(type: "integer", description: "Use next_offset for the next page; omit for the first page")], required: ["app_bundle_id"])
        case "run_workflow": return .init(properties: ["id": .init(type: "string", description: "Exact workflow id"), "revision": .init(type: "string", description: "Exact revision"), "texts": .init(type: "array", description: "One exact text per input_fields entry, in order; [] when none", itemsType: "string")], required: ["id", "revision", "texts"])
        default: return .init(properties: ["name": .init(type: "string", description: "Stable reusable workflow name, no task-specific personal content")], required: ["name"])
        }
    }
    public func execute(parameters: [String: Any]) async throws -> AgentToolResult { throw AssistantError.invalid("流程工具需要当前任务上下文。") }
    public func execute(context: ToolContext) async throws -> AgentToolResult {
        try Task.checkCancellation(); guard await canAccess() else { throw CancellationError() }
        do {
            let result: String
            switch name {
            case "list_workflows":
                guard Set(context.parameters.keys).isSubset(of: ["app_bundle_id", "offset"]), let app = context.parameters["app_bundle_id"] as? String, !app.isEmpty else { throw AssistantError.invalid("缺少 App 标识。") }
                let matches = snapshot.filter { $0.trace.appBundleID == app }
                var offset = 0
                if let value = context.parameters["offset"] {
                    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
                          n.doubleValue.rounded() == n.doubleValue, n.doubleValue >= 0, n.doubleValue <= Double(matches.count) else { throw AssistantError.invalid("流程分页参数无效。") }
                    offset = n.intValue
                }
                let rows: [[String: Any]] = matches.dropFirst(offset).prefix(4).map { item in
                    let fields: [[String: String]] = item.trace.steps.compactMap { step in
                        guard case .insert(let key) = step.action else { return nil }
                        return ["key": key, "description": step.purpose]
                    }
                    return ["id": item.id.uuidString, "revision": item.revision.uuidString, "name": item.trace.name,
                            "app_version": item.trace.appVersion, "steps": item.trace.steps.count,
                            "input_fields": fields, "verified_replays": item.successfulReplays]
                }
                result = String(decoding: try JSONSerialization.data(withJSONObject: ["workflows": rows, "total": matches.count, "next_offset": offset + rows.count < matches.count ? (offset + rows.count) as Any : NSNull()], options: [.sortedKeys]), as: UTF8.self)
            case "run_workflow":
                guard Set(context.parameters.keys) == ["id", "revision", "texts"],
                      let id = context.parameters["id"] as? String, let revision = context.parameters["revision"] as? String,
                      let item = snapshot.first(where: { $0.id.uuidString == id && $0.revision.uuidString == revision }),
                      let texts = context.parameters["texts"] as? [String], texts.count == item.trace.argumentKeys.count else {
                    throw AssistantError.invalid("流程不属于本轮启用快照，或文本参数数量不匹配。")
                }
                try await run(item, Dictionary(uniqueKeysWithValues: zip(item.trace.argumentKeys, texts)), context.callId)
                result = "流程步骤已逐项送达，结束页面的本机特征比对通过。过程中没有调用 OCR 或上传截图。此回执不证明动态内容或业务结果；如任务需要阅读/核实结果，请重新观察。"
            case "name_workflow":
                guard Set(context.parameters.keys) == ["name"], let value = context.parameters["name"] as? String,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 100 else { throw AssistantError.invalid("流程名称无效。") }
                try await label(value); result = "已标记流程名称；当前任务结束后依据实际操作证据异步生成候选，不会立即启用。"
            default: throw AssistantError.invalid("未知流程工具。")
            }
            try Task.checkCancellation(); guard await canAccess() else { throw CancellationError() }
            context.actions.skipSummarization = true
            return .success(toolCallId: context.callId, toolName: name, result: result)
        } catch {
            if Task.isCancelled || error is CancellationError { throw error }
            return .error(toolCallId: context.callId, toolName: name, message: error.localizedDescription)
        }
    }
}
