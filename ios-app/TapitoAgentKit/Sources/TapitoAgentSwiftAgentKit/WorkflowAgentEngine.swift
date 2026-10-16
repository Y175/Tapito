import Foundation
import CoreFoundation
import SwiftAgentKit
import ProviderCore
import TapitoAgentCore

/// Structured M1 output. The host validates exact IDs before touching a device.
public struct RoutedTask: Codable, Sendable {
    public let kind: String
    public let target_mode: String
    public let app_bundle_id: String?
    public let app_name: String?
    public let skill_ids: [String]
    public let flow_id: UUID?
    public let flow_revision: UUID?
    public let texts: [String]
    public let page_calls: [PageCapabilityCall]
    public let requires_summary: Bool
    public let completion_kind: String
    public let question: String?
}

/// Program-owned execution: preparation and published workflows bypass per-action model decisions.
/// Only the bounded unknown-page loop uses model tool calls; tools still share the original host executor.
@MainActor public final class WorkflowAgentEngine: AssistantEngine {
    private let provider: any ModelProvider
    private let model: String
    private let query: String
    private let maxTokens: Int?
    private let maxTurns: Int
    private let tools: [any AgentTool]
    private let skills: [SkillPackage]
    private let additions: [LearnedSkill]
    private var installedApps = Set<String>()
    private let flows: [LearnedWorkflow]
    private let pages: [PageCapability]
    private let runPages: @Sendable ([PageCapabilityCall], String, String) async throws -> Void
    private let receipt: @MainActor (AssistantToolCall, AssistantToolResult) -> Void
    private let diagnostic: @Sendable (String) -> Void
    private let cancelProvider: @Sendable () -> Void
    private var messages: [ModelMessage]
    private var observer: (@MainActor (AssistantEvent) -> Void)?
    private var cancelled = false
    private var used = false
    private var turn = 0
    private var dispatchedIDs = Set<String>()
    private var needsObservation = false
    private var correctionCount = 0
    private let state = AgentState()

    public init(provider: any ModelProvider, model: String, query: String, images: [ModelImage],
                history: [AssistantMessage], maxTokens: Int?, maxTurns: Int, tools: [any AgentTool],
                skills: [SkillPackage], workflows: [LearnedWorkflow], pages: [PageCapability], additions: [LearnedSkill] = [],
                runPages: @escaping @Sendable ([PageCapabilityCall], String, String) async throws -> Void,
                receipt: @escaping @MainActor (AssistantToolCall, AssistantToolResult) -> Void,
                diagnostic: @escaping @Sendable (String) -> Void, cancelProvider: @escaping @Sendable () -> Void) {
        self.provider = provider; self.model = model; self.query = query; self.maxTokens = maxTokens
        self.maxTurns = maxTurns; self.tools = tools; self.skills = skills; self.additions = additions; flows = workflows; self.pages = pages
        self.runPages = runPages; self.receipt = receipt; self.diagnostic = diagnostic; self.cancelProvider = cancelProvider
        messages = [.system(WorkflowPrompts.common + "\n" + WorkflowPrompts.execution + "\n" + WorkflowPrompts.answer)]
        messages += history.map { $0.isUser ? .user($0.text) : .assistant($0.text) }
        messages.append(.user(query, images: images))
    }
    public func cancel() { cancelled = true; cancelProvider() }
    private func check() throws {
        try Task.checkCancellation()
        if cancelled { throw AssistantError.cancelled }
    }
    private func appendContext(_ role: String, _ value: [String: Any]) throws {
        let envelope: [String: Any] = ["role": role, "prompt_revision": WorkflowPrompts.revision, "host_context": value]
        messages.append(.user(String(decoding: try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]), as: UTF8.self)))
    }
    private func request(role: String, definitions: [ModelToolDefinition], visible: Bool) async throws -> ModelResponse {
        try check()
        guard turn < maxTurns else { throw AssistantError.unavailable("模型节点预算已用完；任务已停止，未重放操作。") }
        turn += 1
        diagnostic("workflow.model.started role=\(role) turn=\(turn) prompt=\(WorkflowPrompts.revision)")
        observer?(.llmCallStarted(turn: turn))
        let start = Date()
        do {
            let request = ModelRequest(model: model, messages: messages, maxTokens: maxTokens, tools: definitions)
            diagnostic("workflow.model.request role=\(role) turn=\(turn) request=\(request.id)")
            var terminal: ModelResponse?
            for try await event in provider.stream(request) {
                try check()
                switch event {
                case .terminal(let result):
                    guard terminal == nil else { throw AssistantError.invalid("模型重复返回结束事件。") }
                    terminal = result
                case .error(let error): throw error
                case .text(let chunk):
                    guard terminal == nil else { throw AssistantError.invalid("模型结束后仍有文本事件。") }
                    if visible { observer?(.streamChunk(chunk)) }
                    observer?(.modelProgress)
                case .reasoning, .progress, .toolCall: observer?(.modelProgress)
                case .finish: throw AssistantError.invalid("正式模型适配器必须返回完整 terminal，不能用不完整结束事件执行动作。")
                }
            }
            guard let response = terminal else { throw AssistantError.invalid("模型流未返回完整结束结果。") }
            try check()
            guard response.status == .completed, response.finishReason != .length, response.finishReason != .contentFilter else {
                throw AssistantError.invalid("模型节点 \(role) 输出未完整结束；不执行部分工具调用。")
            }
            messages.append(.assistant(content: response.text, toolCalls: response.toolCalls, replayState: response.replayState))
            observer?(.llmCallCompleted(turn: turn, response: .init(text: visible ? response.text : "", totalTokens: response.usage?.totalTokens)))
            diagnostic("workflow.model.completed role=\(role) turn=\(turn) ms=\(Int(Date().timeIntervalSince(start) * 1000)) tools=\(response.toolCalls.count)")
            return response
        } catch {
            diagnostic("workflow.model.failed role=\(role) turn=\(turn) errorType=\(String(describing: type(of: error)))")
            throw error
        }
    }
    private func definitions(_ tools: [any AgentTool]) throws -> [ModelToolDefinition] {
        try tools.map { tool in
            let properties = try tool.parameters.properties.mapValues { property -> [String: Any] in
                var value: [String: Any] = ["type": property.type, "description": property.description]
                if let values = property.enum { value["enum"] = values }
                if property.type == "array" {
                    guard let type = property.itemsType else { throw AssistantError.invalid("数组工具缺少元素类型。") }
                    value["items"] = ["type": type]
                }
                return value
            }
            return .init(name: tool.name, description: tool.description,
                parameters: ["type": "object", "properties": properties, "required": tool.parameters.required, "additionalProperties": false])
        }
    }
    private func validate(_ parameters: [String: Any], tool: any AgentTool) throws {
        guard Set(parameters.keys).isSubset(of: Set(tool.parameters.properties.keys)),
              Set(tool.parameters.required).isSubset(of: Set(parameters.keys)) else {
            throw AssistantError.invalid("工具参数缺失或含未知字段：" + tool.name)
        }
        for (key, value) in parameters {
            guard let property = tool.parameters.properties[key] else { throw AssistantError.invalid("未知工具字段。") }
            switch property.type {
            case "string": guard let text = value as? String, property.enum == nil || property.enum!.contains(text) else { throw AssistantError.invalid("工具文本字段无效：" + key) }
            case "integer":
                guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
                      n.doubleValue.rounded() == n.doubleValue else { throw AssistantError.invalid("工具整数字段无效：" + key) }
            case "array": guard property.itemsType == "string", value is [String] else { throw AssistantError.invalid("工具数组字段无效：" + key) }
            default: throw AssistantError.invalid("当前执行器不支持此工具字段类型：" + property.type)
            }
        }
        if tool.name == "launch_app" {
            guard let id = parameters["bundle_id"] as? String, installedApps.contains(id) else {
                throw AssistantError.invalid("启动目标不属于本轮已验证的 App 目录。")
            }
        }
    }
    private func execute(name: String, parameters: [String: Any], id: String = UUID().uuidString) async throws -> AgentToolResult {
        try check()
        guard dispatchedIDs.insert(id).inserted, let tool = tools.first(where: { $0.name == name }) else {
            throw AssistantError.invalid("重复工具调用 ID 或未注册工具：\(name)")
        }
        try validate(parameters, tool: tool)
        let call = try SwiftAgentEngine.call(.init(id: id, name: name, parameters: parameters.mapValues(AnyCodable.init)))
        observer?(.toolCallsReceived([call])); observer?(.toolExecutionStarted(call: call))
        let context = ToolContext(callId: id, toolName: name, parameters: parameters, state: state, turn: turn, query: query)
        var recorded = false
        do {
            let result = try await tool.execute(context: context)
            let output = SwiftAgentEngine.result(result)
            receipt(call, output); observer?(.toolExecutionFinished(call: call, result: output)); recorded = true
            try check()
            // A tool error is terminal here. It cannot masquerade as a missing UI target or be retried.
            guard !result.isError else { throw AssistantError.unavailable(result.result) }
            if ["tap", "tap_text", "drag", "home", "launch_app", "type_text", "run_workflow"].contains(name) { needsObservation = true }
            if ["observe_screen", "screenshot"].contains(name) { needsObservation = false }
            return result
        } catch {
            if !recorded {
                let result = AssistantToolResult(result: error.localizedDescription, isError: true)
                receipt(call, result); observer?(.toolExecutionFinished(call: call, result: result))
            }
            throw error
        }
    }
    private func hostTool(_ name: String, _ parameters: [String: Any]) async throws -> AgentToolResult {
        let result = try await execute(name: name, parameters: parameters)
        try appendContext("program_tool_result", ["name": name, "result": result.result])
        return result
    }
    private func answer(role: String = "M5") async throws -> String {
        try appendContext(role, ["instruction": WorkflowPrompts.answer])
        let response = try await request(role: role, definitions: [], visible: true)
        guard response.toolCalls.isEmpty, !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AssistantError.invalid("回答节点返回了工具调用或空答复。")
        }
        return response.text
    }

    public func run(context: String, onEvent: @escaping @MainActor (AssistantEvent) -> Void) async throws -> String {
        guard !used else { throw AssistantError.invalid("工作流引擎只能执行一次。") }
        used = true; observer = onEvent
        guard (2...128).contains(maxTurns) else { throw AssistantError.invalid("工作流模型预算必须为 2–128 次。") }
        guard Set(tools.map(\.name)).count == tools.count else { throw AssistantError.invalid("工具注册名称重复。") }
        let flowCatalog = flows.map { ["id": $0.id.uuidString, "revision": $0.revision.uuidString, "name": $0.trace.name,
                                      "app": $0.trace.appBundleID, "arguments": $0.trace.argumentKeys] as [String: Any] }
        let pageCatalog = pages.filter { !$0.requiresFreshSemanticCheck }.map { ["id": $0.id.uuidString, "revision": $0.revision.uuidString, "app": $0.evidence.appBundleID,
                                      "page": $0.pageName, "function": $0.function, "result": $0.observedResult,
                                      "control": $0.evidence.control.text,
                                      "page_ui": $0.evidence.before.anchors.map(\.text),
                                      "result_ui": $0.evidence.after.anchors.map(\.text),
                                      "requires_text": $0.evidence.action == .focusAndType] as [String: Any] }
        try appendContext("M1", ["instruction": WorkflowPrompts.intent, "memory": context,
            "skills": skills.map { ["id": $0.id.uuidString, "name": $0.name, "description": $0.summary] },
            "workflows": flowCatalog, "page_capabilities": pageCatalog])
        let routed = try await request(role: "M1", definitions: [Self.routeDefinition], visible: false)
        guard routed.toolCalls.count == 1, let call = routed.toolCalls.first, call.name == "route_task" else {
            throw AssistantError.invalid("M1 必须返回一个 route_task；未启动设备操作。")
        }
        let task: RoutedTask
        do {
            guard dispatchedIDs.insert(call.id).inserted,
                  let object = call.decodedArguments(),
                  let required = Self.routeDefinition.parameters["required"] as? [String],
                  Set(object.keys) == Set(required) else {
                throw AssistantError.invalid("路由字段缺失或包含未知字段。")
            }
            task = try JSONDecoder().decode(RoutedTask.self, from: Data(call.arguments.utf8))
        }
        catch { throw AssistantError.invalid("M1 任务结构无效；未启动设备操作。") }
        guard ["conversation", "device_task", "clarify"].contains(task.kind),
              Set(task.skill_ids).isSubset(of: Set(skills.map { $0.id.uuidString })),
              task.page_calls.isEmpty || task.flow_id == nil,
              ["page_transition", "dynamic_read", "business_result", "conversation"].contains(task.completion_kind),
              (task.flow_id == nil) == (task.flow_revision == nil), task.page_calls.count <= 16,
              task.flow_id != nil || task.texts.isEmpty,
              ["none", "app", "current_screen"].contains(task.target_mode),
              task.kind == "device_task" ? task.target_mode != "none" : task.target_mode == "none" else {
            throw AssistantError.invalid("任务类型、技能引用或流程选择冲突。")
        }
        messages.append(.tool("任务结构已校验；由程序路由。", toolCallId: call.id))
        if task.kind == "clarify" {
            guard let question = task.question, !question.isEmpty else { throw AssistantError.invalid("澄清节点缺少问题。") }
            observer?(.programAnswer(question))
            return question
        }
        if task.kind == "conversation" { return try await answer() }

        // Device preparation happens once. Current-screen tasks do not invent a target App.
        let app: String?
        if task.target_mode == "app" {
            let apps = try await hostTool("list_apps", [:])
            guard let rows = try JSONSerialization.jsonObject(with: Data(apps.result.utf8)) as? [[String: Any]] else {
                throw AssistantError.invalid("已安装 App 目录格式错误。")
            }
            let identifiers = try rows.map { row -> String in
                guard let id = row["bundle_id"] as? String, !id.isEmpty else { throw AssistantError.invalid("App 目录存在缺失标识的条目。") }
                return id
            }
            guard Set(identifiers).count == identifiers.count else { throw AssistantError.invalid("App 目录包含重复标识。") }
            installedApps = Set(identifiers)
            let matches = rows.filter {
                if let id = task.app_bundle_id { return $0["bundle_id"] as? String == id }
                if let name = task.app_name { return ($0["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame }
                return false
            }
            guard matches.count == 1, let resolved = matches[0]["bundle_id"] as? String else {
                throw AssistantError.invalid("目标 App 未唯一匹配已安装目录；请明确应用名称。")
            }
            app = resolved
        } else {
            guard task.app_bundle_id == nil, task.app_name == nil, task.flow_id == nil, task.page_calls.isEmpty else {
                throw AssistantError.invalid("当前屏幕任务不能绑定未经确认的 App 流程。")
            }
            app = nil
        }
        let builtInBindings = ["com.apple.mobilenotes": "ios-notes", "com.apple.mobiletimer": "ios-clock",
                               "com.tencent.xin": "wechat", "com.sina.weibo": "weibo", "com.tencent.mqq": "qq"]
        let matchedSkill = app.flatMap { builtInBindings[$0] }
        let selectedSkills = skills.filter { task.skill_ids.contains($0.id.uuidString) || $0.name == "ios-operation" || $0.name == matchedSkill }
        guard selectedSkills.contains(where: { $0.name == "ios-operation" }) else {
            throw AssistantError.invalid("设备任务缺少已启用的 ios-operation 基础技能。")
        }
        let documents = selectedSkills.flatMap { skill in
            let approved = additions.filter { $0.active && !$0.disabled && $0.baseSkillID == skill.id.uuidString && $0.baseRevision == skill.revision }
            let supplement = approved.map { "\n用户审核的流程补充，仅适用 App \($0.appBundleID)：\n\($0.instructions)" }.joined()
            return skill.documents.keys.sorted().map { ["skill": skill.name, "resource": $0,
                "content": skill.documents[$0]! + ($0 == "SKILL.md" ? supplement : "")] }
        }
        guard documents.reduce(0, { $0 + ($1["content"]?.utf8.count ?? 0) }) <= 96_000 else {
            throw AssistantError.invalid("本轮技能文档超过 96 KB，请缩减所选技能；未截断指令。")
        }
        try appendContext("P1", ["target_mode": task.target_mode, "app": app as Any? ?? NSNull(), "skills": documents])
        if let flowID = task.flow_id {
            guard let app, let flow = flows.first(where: { $0.id == flowID && $0.revision == task.flow_revision && $0.trace.appBundleID == app }),
                  task.texts.count == flow.trace.argumentKeys.count else { throw AssistantError.invalid("已知流程或文本参数不匹配。") }
            _ = try await hostTool("run_workflow", ["id": flow.id.uuidString, "revision": flow.revision.uuidString, "texts": task.texts])
            _ = try await hostTool("observe_screen", [:])
            return try await answer()
        }
        // Reject unknown capability references and parameters before any launch/input.
        for call in task.page_calls {
            guard let item = pages.first(where: { $0.id == call.id && $0.revision == call.revision && $0.state == "active" }),
                  item.evidence.appBundleID == app else { throw AssistantError.invalid("页面能力不属于已发布版本或目标 App。") }
            try item.validate()
            guard !item.requiresFreshSemanticCheck else { throw AssistantError.invalid("当前控件需要 M3 核实本次业务上下文，不能直接回放。") }
            if item.evidence.action == .focusAndType {
                guard let text = call.text, !text.isEmpty, text.utf8.count <= 8192, !text.contains("\0") else { throw AssistantError.invalid("页面输入参数无效。") }
            } else if call.text != nil { throw AssistantError.invalid("点击能力不接受文本参数。") }
        }
        if let app { _ = try await hostTool("launch_app", ["bundle_id": app, "purpose": "打开本轮任务的目标应用"]) }
        if !task.page_calls.isEmpty {
            guard let app else { throw AssistantError.invalid("页面能力缺少目标 App。") }
            do {
                try await runPages(task.page_calls, app, UUID().uuidString)
                needsObservation = false
                try appendContext("P7", ["result": "已发布页面能力序列执行完毕，前后页面骨架均匹配。业务内容与发送效果尚需单独核实。"])
                let writesBusinessData = task.page_calls.contains { call in
                    pages.contains { item in item.id == call.id && (item.evidence.action == .focusAndType ||
                        ["发送", "保存", "删除", "确定", "确认", "Send", "Save"].contains(item.evidence.control.text)) }
                }
                if task.completion_kind == "page_transition", !task.requires_summary, !writesBusinessData {
                    let text = "已完成页面操作，并核对目标页面。"
                    observer?(.programAnswer(text))
                    return text
                }
                _ = try await hostTool("observe_screen", [:])
                return try await answer()
            } catch let error as PageWorkflowDeviation {
                correctionCount += 1
                try appendContext("M4", ["error": error.localizedDescription,
                    "completed_capabilities": task.page_calls.prefix(error.completed).map { $0.id.uuidString },
                    "current_capability": error.capabilityID.uuidString, "current_input_delivered": error.inputDelivered,
                    "instruction": "只修正剩余部分，禁止重放已完成段；当前段已送达时先核实效果，不能重发输入。"])
            }
        }
        // Unknown tasks retain an explicit, bounded ReAct branch; it cannot reload all preparation.
        let executionTools = tools.filter { !["load_skill", "list_apps", "search_memory", "remember_memory",
                                              "propose_skill_update", "list_workflows", "run_workflow", "name_workflow", "finish"].contains($0.name) }
        let availableExecutionTools = executionTools.filter { $0.name != "launch_app" || !installedApps.isEmpty }
        let schemas = try definitions(availableExecutionTools)
        // Observation is a fixed program node, not a model request asking whether OCR is necessary.
        _ = try await hostTool("observe_screen", [:])
        try appendContext(correctionCount > 0 ? "M4" : "M2", ["instruction": WorkflowPrompts.execution])
        var role = correctionCount > 0 ? "M4" : "M2"
        while turn < maxTurns {
            let response = try await request(role: role, definitions: schemas, visible: false)
            if response.toolCalls.isEmpty {
                guard !response.text.isEmpty else { throw AssistantError.invalid("执行节点没有返回工具调用或答复。") }
                if needsObservation {
                    // Program-enforced final observation, never an extra model vote on whether to take a screenshot.
                    _ = try await hostTool("observe_screen", [:])
                    return try await answer()
                }
                observer?(.programAnswer(response.text))
                return response.text
            }
            guard response.toolCalls.count <= 16, Set(response.toolCalls.map(\.id)).count == response.toolCalls.count else {
                throw AssistantError.invalid("工具批次过大或 ID 重复。")
            }
            // Preflight the whole batch before the first action. Unknown names cannot partially execute.
            for toolCall in response.toolCalls {
                guard let tool = availableExecutionTools.first(where: { $0.name == toolCall.name }), !dispatchedIDs.contains(toolCall.id),
                      let parameters = toolCall.decodedArguments() else { throw AssistantError.invalid("工具批次包含未知工具、重复 ID 或无效参数。") }
                try validate(parameters, tool: tool)
            }
            var correction: String?
            for toolCall in response.toolCalls {
                if correction != nil {
                    // Satisfy provider correlation without executing the rest of an invalidated batch.
                    dispatchedIDs.insert(toolCall.id)
                    messages.append(.tool("未执行：前一步要求重新观察。", toolCallId: toolCall.id))
                    continue
                }
                guard let parameters = toolCall.decodedArguments() else { throw AssistantError.invalid("工具参数必须是 JSON 对象。") }
                do {
                    let result = try await execute(name: toolCall.name, parameters: parameters, id: toolCall.id)
                    messages.append(.init(role: .tool, content: result.result, images: result.images, toolCallId: toolCall.id))
                } catch let error as WorkflowCorrectionRequired {
                    correction = error.message
                    messages.append(.tool("未发送输入：" + error.message, toolCallId: toolCall.id))
                }
            }
            if let correction {
                correctionCount += 1
                guard correctionCount <= 2 else { throw AssistantError.unavailable("页面纠错预算已用完，未重放操作。") }
                try appendContext("M4", ["error": correction, "instruction": "纠正未发送动作，优先复用有效帧；禁止重复已执行步骤。"])
                role = "M4"
            } else {
                if needsObservation { _ = try await hostTool("observe_screen", [:]) }
                role = "M3"
            }
        }
        throw AssistantError.unavailable("任务达到模型调用预算，已停止；不会重放已发送操作。")
    }

    public static var routeDefinition: ModelToolDefinition {
        let nullableString: [String: Any] = ["type": ["string", "null"]]
        let properties: [String: Any] = [
            "kind": ["type": "string", "enum": ["conversation", "device_task", "clarify"]],
            "target_mode": ["type": "string", "enum": ["none", "app", "current_screen"]],
            "app_bundle_id": nullableString, "app_name": nullableString, "question": nullableString,
            "skill_ids": ["type": "array", "items": ["type": "string"]],
            "flow_id": nullableString, "flow_revision": nullableString,
            "texts": ["type": "array", "items": ["type": "string"]],
            "requires_summary": ["type": "boolean"],
            "completion_kind": ["type": "string", "enum": ["page_transition", "dynamic_read", "business_result", "conversation"]],
            "page_calls": ["type": "array", "items": ["type": "object", "properties": ["id": ["type": "string"], "revision": ["type": "string"], "text": nullableString],
                        "required": ["id", "revision", "text"], "additionalProperties": false]]
        ]
        return .init(name: "route_task", description: "输出任务结构，仅用于程序路由，不执行任何设备动作。",
                     parameters: ["type": "object", "properties": properties, "required": Array(properties.keys).sorted(), "additionalProperties": false])
    }
}
