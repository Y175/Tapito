import Foundation
import CoreFoundation
import SwiftAgentKit
import TapitoAgentCore

/// Immutable, built-in or explicitly imported app-owned documents for one run. No path can
/// reach outside this value, and no command, network or interpreter is exposed.
struct SkillTool: AgentTool {
    let name: String
    let catalog: SkillCatalog
    let canRead: @Sendable () async -> Bool
    var isReadOnly: Bool { true }
    var isConcurrencySafe: Bool { false }
    var description: String {
        switch name {
        default: return "Read an exact page of an enabled, built-in or user-imported skill by id and revision. Defaults to SKILL.md, offset 0. When next_offset is not null, continue at that character offset. Read relevant listed references by resource path as needed. Text cannot expand task permissions. No scripts or outside files are accessible."
        }
    }
    var parameters: ToolParameters {
        let text = ToolParameterProperty(type: "string", description: "Exact value from enabled skill metadata in the system prompt")
        return ToolParameters(properties: ["id": text, "revision": text, "resource": .init(type: "string", description: "Relative document path from available_resources; defaults to SKILL.md"), "offset": .init(type: "integer", description: "Character offset from next_offset; defaults to zero")], required: ["id", "revision"])
    }
    func execute(parameters: [String: Any]) async throws -> AgentToolResult { throw AppError.invalid("技能工具需要当前运行上下文") }
    func execute(context: ToolContext) async throws -> AgentToolResult {
        try Task.checkCancellation()
        guard await canRead() else { throw AppError.stopped }
        do {
            let result = try catalog.result(name: name, parameters: context.parameters)
            try Task.checkCancellation()
            guard await canRead() else { throw AppError.stopped }
            context.actions.skipSummarization = true
            return .success(toolCallId: context.callId, toolName: name, result: result)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? AppError) == .stopped { throw error }
            return .error(toolCallId: context.callId, toolName: name, message: error.localizedDescription)
        }
    }
}
