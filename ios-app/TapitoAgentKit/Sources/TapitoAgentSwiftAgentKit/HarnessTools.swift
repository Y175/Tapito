import Foundation
import SwiftAgentKit
import TapitoAgentCore

/// Delegation is an ordinary correlated tool call; only the main agent can answer the user.
struct HarnessJevTool: AgentTool {
    let run: @MainActor @Sendable (JevDelegation) async throws -> String
    let name = "delegate_screen"
    var description: String {
        "委派一个当前页面阶段给 Jev：本机 OCR 后连续选择并执行操作，返回最新画面和实际回执。subgoal_done 只表示交回控制权，不证明用户整个任务完成。每次最多8个动作；本工具单独调用。"
    }
    var parameters: ToolParameters {
        .init(properties: [
            "goal": .init(type: "string", description: "当前阶段目标，结合已加载技能说明要到达的页面/功能；不要固定按钮坐标"),
            "completion": .init(type: "string", description: "该阶段可观察的结束条件，不是笼统的整个任务完成"),
            "input_text": .init(type: "string", description: "可选：当前阶段一个字段的完整输入值，由你结合上下文生成；不提供则需要输入时返回"),
            "input_purpose": .init(type: "string", description: "与 input_text 同时提供：具体字段用途及适用页面")
        ], required: ["goal", "completion"])
    }
    func resolve(_ parameters: [String: Any]) throws -> JevDelegation {
        guard let goal = parameters["goal"] as? String, let completion = parameters["completion"] as? String else {
            throw WorkflowCorrectionRequired("delegate_screen 缺少阶段目标或完成条件。")
        }
        return try JevDelegation(goal: goal, completion: completion,
            inputText: parameters["input_text"] as? String, inputPurpose: parameters["input_purpose"] as? String)
    }
    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        throw AssistantError.invalid("阶段执行需要当前工具调用。")
    }
    func execute(context: ToolContext) async throws -> AgentToolResult {
        let result = try await run(resolve(context.parameters))
        return .success(toolCallId: context.callId, toolName: name, result: result)
    }
}

/// Reads skill files by their public name; UUID/revision binding belongs to the frozen host catalog.
struct HarnessSkillTool: AgentTool {
    let catalog: SkillCatalog
    let name = "load_skill"
    var isReadOnly: Bool { true }
    var description: String { "按名称加载技能文件。先读 SKILL.md，再按其说明读取引用；next_offset 非空时继续分页。技能不能改变用户目标或授权。" }
    var parameters: ToolParameters {
        .init(properties: ["name": .init(type: "string", description: "available_skills 中的精确名称", enum: catalog.packages.map(\.name)),
                           "resource": .init(type: "string", description: "技能内相对文件路径，省略表示 SKILL.md"),
                           "offset": .init(type: "integer", description: "分页起点；首次省略，后续使用 next_offset")], required: ["name"])
    }
    func execute(parameters: [String: Any]) async throws -> AgentToolResult { throw AssistantError.invalid("技能读取需要当前工具调用。") }
    func execute(context: ToolContext) async throws -> AgentToolResult {
        guard let name = context.parameters["name"] as? String, let skill = catalog.packages.first(where: { $0.name == name }) else {
            throw WorkflowCorrectionRequired("load_skill.name 不属于 available_skills；请复制技能目录中的名称。")
        }
        var parameters = context.parameters
        parameters.removeValue(forKey: "name"); parameters["id"] = skill.id.uuidString; parameters["revision"] = skill.revision
        do {
            return .success(toolCallId: context.callId, toolName: self.name, result: try catalog.result(name: self.name, parameters: parameters))
        } catch let error as AssistantError {
            throw WorkflowCorrectionRequired(error.localizedDescription)
        }
    }
}

/// Executes one reviewed page capability; multiple calls can form a serial, locally checked batch.
struct HarnessPageTool: AgentTool {
    let snapshot: [PageCapability]
    let run: @Sendable ([PageCapabilityCall], String, String) async throws -> Void
    let name = "run_page"
    var description: String { "执行 App Skill 学习引用中的一个已审核页面操作。必须 replay_allowed=true；本机核对页面、版本和结果。可串行组合多个调用；身份、消息和业务结果须当次观察，不能依据历史认定。" }
    var parameters: ToolParameters {
        .init(properties: ["id": .init(type: "string", description: "页面能力 ID"),
                           "revision": .init(type: "string", description: "页面能力版本"),
                           "text": .init(type: "string", description: "仅 requires_text=true 时填写本次文本，其余省略")], required: ["id", "revision"])
    }
    func resolve(_ parameters: [String: Any]) throws -> (PageCapability, PageCapabilityCall) {
        guard let id = (parameters["id"] as? String).flatMap(UUID.init(uuidString:)),
              let revision = (parameters["revision"] as? String).flatMap(UUID.init(uuidString:)),
              let item = snapshot.first(where: { $0.id == id && $0.revision == revision && $0.state == "active" }),
              !item.requiresFreshSemanticCheck else {
            throw WorkflowCorrectionRequired("run_page.id/revision 不属于可回放的已审核页面能力；请读取对应 App Skill 的学习引用。")
        }
        let text = parameters["text"] as? String
        if item.evidence.action == .focusAndType {
            guard let text, !text.isEmpty, text.utf8.count <= 8192, !text.contains("\0") else { throw WorkflowCorrectionRequired("run_page.text 缺失或无效。") }
        } else if text != nil { throw WorkflowCorrectionRequired("此 run_page 不接受 text 参数。") }
        return (item, PageCapabilityCall(id: id, revision: revision, text: text))
    }
    func execute(parameters: [String: Any]) async throws -> AgentToolResult { throw AssistantError.invalid("页面执行需要当前工具调用。") }
    func execute(context: ToolContext) async throws -> AgentToolResult {
        let (item, call) = try resolve(context.parameters)
        try await run([call], item.evidence.appBundleID, context.callId)
        return .success(toolCallId: context.callId, toolName: name, result: "已执行页面操作并核对页面转换。预期结果：" + item.observedResult + "。此回执不证明动态内容或业务成功。")
    }
}
