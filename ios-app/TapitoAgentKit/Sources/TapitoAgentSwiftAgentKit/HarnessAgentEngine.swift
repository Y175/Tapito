import Foundation
import CoreFoundation
import SwiftAgentKit
import ProviderCore
import TapitoAgentCore

/// UI-independent ReAct harness. The model selects skills/tools; the host validates and serially executes them.
@MainActor public final class HarnessAgentEngine: AssistantEngine {
    private let provider: any ModelProvider
    private let model: String
    private let query: String
    private let maxTokens: Int?
    private let maxTurns: Int
    private let suppliedTools: [any AgentTool]
    private let skills: [SkillPackage]
    private let additions: [LearnedSkill]
    private let flows: [LearnedWorkflow]
    private let pages: [PageCapability]
    private let runPages: @Sendable ([PageCapabilityCall], String, String) async throws -> Void
    private let receipt: @MainActor (AssistantToolCall, AssistantToolResult) -> Void
    private let diagnostic: @MainActor (String) -> Void
    private let cancelProvider: @Sendable () -> Void
    /// Optional screen selector; the same Harness remains the owner of task state and final answers.
    private let jev: (any JevDecisionProviding)?
    /// Reusable first OCR page, invalidated by every page-changing action or pixel observation.
    private var lastOCR: String?
    private var tools: [any AgentTool] = []
    private var messages: [ModelMessage]
    private var observer: (@MainActor (AssistantEvent) -> Void)?
    private var loadedSkills = Set<String>()
    private var installedApps = Set<String>()
    private var dispatchedIDs = Set<String>()
    private var cancelled = false
    private var used = false
    private var turn = 0
    private var needsObservation = false
    private var correctionCount = 0
    private let state = AgentState()

    /// All platform actions and persistence are injected; a run has an immutable skill and learning snapshot.
    public init(provider: any ModelProvider, model: String, query: String, images: [ModelImage],
                history: [AssistantMessage], maxTokens: Int?, maxTurns: Int, tools: [any AgentTool],
                skills: [SkillPackage], workflows: [LearnedWorkflow], pages: [PageCapability], additions: [LearnedSkill] = [],
                runPages: @escaping @Sendable ([PageCapabilityCall], String, String) async throws -> Void,
                receipt: @escaping @MainActor (AssistantToolCall, AssistantToolResult) -> Void,
                diagnostic: @escaping @MainActor (String) -> Void, cancelProvider: @escaping @Sendable () -> Void,
                jev: (any JevDecisionProviding)? = nil) {
        self.provider = provider; self.model = model; self.query = query; self.maxTokens = maxTokens
        self.maxTurns = maxTurns; suppliedTools = tools; self.skills = skills; self.additions = additions
        flows = workflows; self.pages = pages; self.runPages = runPages; self.receipt = receipt
        self.diagnostic = diagnostic; self.cancelProvider = cancelProvider; self.jev = jev
        messages = [.system(WorkflowPrompts.common + "\n" + WorkflowPrompts.execution + (jev == nil ? "" : "\n" + WorkflowPrompts.jevDelegation))]
        messages += history.map { $0.isUser ? .user($0.text) : .assistant($0.text) }
        messages.append(.user(query, images: images))
    }
    public func cancel() { cancelled = true; cancelProvider(); jev?.cancel() }
    private func check() throws {
        try Task.checkCancellation()
        if cancelled { throw AssistantError.cancelled }
    }
    private func appendContext(_ value: [String: Any]) throws {
        messages.append(.user(String(decoding: try JSONSerialization.data(withJSONObject: ["host_context": value], options: [.sortedKeys]), as: UTF8.self)))
    }
    private func request(stage: AssistantModelStage, definitions: [ModelToolDefinition]) async throws -> ModelResponse {
        try check()
        guard turn < maxTurns else { throw AssistantError.unavailable("模型节点预算已用完；任务已停止，未重放操作。") }
        turn += 1
        diagnostic("harness.model.started stage=\(stage.rawValue) turn=\(turn) prompt=\(WorkflowPrompts.revision)")
        observer?(.modelStageChanged(stage))
        observer?(.llmCallStarted(turn: turn))
        let timer = ExecutionStopwatch()
        do {
            let request = ModelRequest(model: model, messages: messages, maxTokens: maxTokens, tools: definitions)
            diagnostic("harness.model.request stage=\(stage.rawValue) turn=\(turn) request=\(request.id)")
            var terminal: ModelResponse?
            var receivedEvent = false
            for try await event in provider.stream(request) {
                try check()
                if !receivedEvent {
                    receivedEvent = true
                    diagnostic("harness.model.first_event turn=\(turn) ms=\(timer.milliseconds)")
                }
                switch event {
                case .terminal(let result):
                    guard terminal == nil else { throw AssistantError.invalid("模型重复返回结束事件。") }
                    terminal = result
                case .error(let error): throw error
                case .text(let chunk):
                    guard terminal == nil else { throw AssistantError.invalid("模型结束后仍有文本事件。") }
                    _ = chunk // Publish only a complete final answer, never a partial action claim.
                    observer?(.modelProgress)
                case .reasoning, .progress, .toolCall: observer?(.modelProgress)
                case .finish: throw AssistantError.invalid("正式模型适配器必须返回完整 terminal，不能用不完整结束事件执行动作。")
                }
            }
            guard let response = terminal else { throw AssistantError.invalid("模型流未返回完整结束结果。") }
            try check()
            guard response.status == .completed, response.finishReason != .length, response.finishReason != .contentFilter else {
                throw AssistantError.invalid("模型节点 输出未完整结束；不执行部分工具调用。")
            }
            messages.append(.assistant(content: response.text, toolCalls: response.toolCalls, replayState: response.replayState))
            observer?(.llmCallCompleted(turn: turn, response: .init(text: "", totalTokens: response.usage?.totalTokens, durationSeconds: timer.seconds)))
            diagnostic("harness.model.completed stage=\(stage.rawValue) turn=\(turn) ms=\(timer.milliseconds) tools=\(response.toolCalls.count)")
            return response
        } catch {
            observer?(.llmCallFailed(turn: turn, durationSeconds: timer.seconds))
            diagnostic("harness.model.failed stage=\(stage.rawValue) turn=\(turn) ms=\(timer.milliseconds) errorType=\(String(describing: type(of: error)))")
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

    /// Counts a multi-question Jev request once in the same budget/timeline as the main model.
    private func evaluateJev(_ state: [String: AssistantValue], _ questions: [JevQuestion]) async throws -> JevEvaluation {
        try check()
        guard let jev else { throw AssistantError.invalid("当前任务未配置 Jev。") }
        guard turn < maxTurns else { throw AssistantError.unavailable("模型节点预算已用完；任务已停止，未重放操作。") }
        turn += 1
        let requestTurn = turn
        let timer = ExecutionStopwatch()
        observer?(.modelStageChanged(.planning)); observer?(.llmCallStarted(turn: requestTurn))
        diagnostic("jev.model.started turn=\(requestTurn) questions=\(questions.count)")
        do {
            let result = try await jev.evaluate(state: state, questions: questions)
            try check()
            observer?(.llmCallCompleted(turn: requestTurn, response: .init(text: "",
                totalTokens: result.inputTokens + result.outputTokens, durationSeconds: timer.seconds)))
            diagnostic("jev.model.completed turn=\(requestTurn) model=\(result.model) ms=\(timer.milliseconds) image_uploaded=false")
            return result
        } catch {
            observer?(.llmCallFailed(turn: requestTurn, durationSeconds: timer.seconds))
            diagnostic("jev.model.failed turn=\(requestTurn) ms=\(timer.milliseconds) type=\(String(describing: type(of: error)))")
            throw error
        }
    }

    /// The executor can call only the registered local action subset, never another delegation.
    private func delegate(_ task: JevDelegation) async throws -> String {
        let executor = JevScreenExecutor(evaluate: { [unowned self] state, questions in
            try await self.evaluateJev(state, questions)
        }, execute: { [unowned self] call in
            try self.check()
            guard ["observe_screen", "tap_text", "type_text", "drag", "wait"].contains(call.name),
                  let tool = self.availableTools.first(where: { $0.name == call.name }) else {
                throw AssistantError.invalid("Jev 选择了未注册的阶段工具。")
            }
            try self.validate(call.parameters.mapValues(\.value), tool: tool)
            self.observer?(.toolCallsReceived([call]))
            let result = try await self.execute(call, tool: tool)
            return .init(result: result.result, isError: result.isError)
        }, check: { [unowned self] in try self.check() }, diagnostic: diagnostic)
        return try await executor.run(task, initialObservation: lastOCR)
    }

    /// Only tools advertised on this reasoning turn may execute. Skill loading activates the shared device group.
    private var availableTools: [any AgentTool] {
        tools.filter { tool in
            if ["load_skill", "list_apps"].contains(tool.name) { return true }
            guard loadedSkills.contains("ios-operation") else { return false }
            if tool.name == "run_workflow" { return flows.contains { $0.state == "active" } }
            return true
        }
    }
    private func validate(_ parameters: [String: Any], tool: any AgentTool) throws {
        func invalid(_ field: String, _ reason: String) -> WorkflowCorrectionRequired {
            diagnostic("harness.validation tool=\(tool.name) field=\(field) rejected=true sent=false")
            return WorkflowCorrectionRequired("\(tool.name).\(field)：\(reason)；本批工具均未执行。")
        }
        for field in tool.parameters.required where parameters[field] == nil { throw invalid(field, "缺少必填参数") }
        guard Set(parameters.keys).isSubset(of: Set(tool.parameters.properties.keys)) else { throw invalid("parameters", "包含未声明字段") }
        for (key, value) in parameters {
            guard let property = tool.parameters.properties[key] else { throw invalid("parameters", "未知字段") }
            switch property.type {
            case "string":
                guard let text = value as? String, property.enum == nil || property.enum!.contains(text) else { throw invalid(key, "应为声明范围内的字符串") }
            case "integer":
                guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
                      n.doubleValue.rounded() == n.doubleValue else { throw invalid(key, "应为整数") }
            case "array":
                guard property.itemsType == "string", value is [String] else { throw invalid(key, "应为字符串数组") }
            default: throw AssistantError.invalid("工具注册包含不支持的参数类型：" + tool.name)
            }
        }
        if tool.name == "launch_app" {
            guard let id = parameters["bundle_id"] as? String, installedApps.contains(id) else {
                throw invalid("bundle_id", "请先调用 list_apps，并复制真实目录中的标识；显示名称语言不影响选择")
            }
        }
        if let delegation = tool as? HarnessJevTool { _ = try delegation.resolve(parameters) }
        if let pageTool = tool as? HarnessPageTool {
            let (item, _) = try pageTool.resolve(parameters)
            try item.validate()
            guard installedApps.contains(item.evidence.appBundleID) else { throw invalid("id", "先查询 App，核对该页面能力的应用已安装") }
        }
        if tool.name == "run_workflow" {
            guard let id = (parameters["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let revision = (parameters["revision"] as? String).flatMap(UUID.init(uuidString:)),
                  let item = flows.first(where: { $0.id == id && $0.revision == revision && $0.state == "active" }),
                  installedApps.contains(item.trace.appBundleID),
                  let texts = parameters["texts"] as? [String], texts.count == item.trace.argumentKeys.count,
                  texts.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8192 && !$0.contains("\0") }) else {
                throw invalid("id/revision/texts", "须来自 App Skill 已审核流程、匹配输入字段数量，且目标属于本轮 App 目录")
            }
        }
    }
    private func call(_ value: ModelToolCall) throws -> AssistantToolCall {
        guard let parameters = value.decodedArguments() else { throw AssistantError.invalid("工具参数必须是 JSON 对象。") }
        return try SwiftAgentEngine.call(.init(id: value.id, name: value.name, parameters: parameters.mapValues(AnyCodable.init)))
    }
    private func record(_ call: AssistantToolCall, _ result: AgentToolResult, duration: TimeInterval? = nil) {
        let output = AssistantToolResult(result: result.result, isError: result.isError, durationSeconds: duration)
        receipt(call, output); observer?(.toolExecutionFinished(call: call, result: output))
    }
    private func execute(_ call: AssistantToolCall, tool: any AgentTool) async throws -> AgentToolResult {
        try check()
        let parameters = call.parameters.mapValues(\.value)
        observer?(.toolExecutionStarted(call: call))
        diagnostic("harness.tool.started tool=\(tool.name) call=\(call.id) turn=\(turn)")
        let timer = ExecutionStopwatch()
        var recorded = false
        do {
            let context = ToolContext(callId: call.id, toolName: tool.name, parameters: parameters, state: state, turn: turn, query: query)
            let raw = try await tool.execute(context: context)
            // Device/transport failures and uncertain input are terminal, never treated as a parameter correction.
            if raw.isError {
                record(call, raw, duration: timer.seconds); recorded = true
                throw AssistantError.unavailable(raw.result)
            }
            let result = try acceptedResult(raw, tool: tool, parameters: parameters)
            record(call, result, duration: timer.seconds); recorded = true
            try check()
            if ["tap", "tap_text", "drag", "home", "launch_app", "type_text", "run_workflow"].contains(tool.name) { needsObservation = true }
            if ["observe_screen", "screenshot", "run_page", "delegate_screen"].contains(tool.name) { needsObservation = false }
            if ["tap", "tap_text", "drag", "home", "launch_app", "type_text", "run_workflow", "run_page", "wait", "screenshot"].contains(tool.name) { lastOCR = nil }
            if tool.name == "observe_screen", parameters["offset"] == nil { lastOCR = result.result }
            diagnostic("harness.tool.completed tool=\(tool.name) call=\(call.id) turn=\(turn) ms=\(timer.milliseconds)")
            return result
        } catch {
            if !recorded { record(call, .error(toolCallId: call.id, toolName: call.name, message: error.localizedDescription), duration: timer.seconds) }
            diagnostic("harness.tool.failed tool=\(tool.name) call=\(call.id) ms=\(timer.milliseconds) type=\(String(describing: type(of: error)))")
            throw error
        }
    }
    /// Catalog validation is data validation, not a second model routing protocol.
    private func acceptedResult(_ result: AgentToolResult, tool: any AgentTool, parameters: [String: Any]) throws -> AgentToolResult {
        if tool.name == "load_skill", let name = parameters["name"] as? String {
            loadedSkills.insert(name)
            diagnostic("harness.skill.loaded name=\(name)")
        }
        guard tool.name == "list_apps" else { return result }
        guard let rows = try JSONSerialization.jsonObject(with: Data(result.result.utf8)) as? [[String: Any]] else {
            throw AssistantError.invalid("已安装 App 目录格式错误。")
        }
        let catalog = try rows.map { row -> [String: String] in
            guard let id = row["bundle_id"] as? String, !id.isEmpty,
                  let name = row["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AssistantError.invalid("App 目录条目缺少标识或名称。")
            }
            return ["bundle_id": id, "name": name]
        }
        let ids = catalog.compactMap { $0["bundle_id"] }
        guard Set(ids).count == ids.count else { throw AssistantError.invalid("App 目录包含重复标识。") }
        installedApps = Set(ids)
        diagnostic("harness.apps.loaded count=\(ids.count)")
        return .success(toolCallId: result.toolCallId, toolName: tool.name,
                        result: String(decoding: try JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys]), as: UTF8.self))
    }
    private func observeAfterInput() async throws {
        guard let tool = tools.first(where: { $0.name == "observe_screen" }) else { throw AssistantError.invalid("设备工具缺少观察能力。") }
        let call = AssistantToolCall(id: UUID().uuidString, name: tool.name, parameters: [:])
        observer?(.toolCallsReceived([call]))
        let result = try await execute(call, tool: tool)
        try appendContext(["program_tool_result": ["name": tool.name, "result": result.result],
                           "instruction": "这是批次操作后的最新 OCR，直接据此继续，不要重复观察或另问是否截图。"])
    }
    private func rejected(_ calls: [AssistantToolCall], reason: String) {
        for call in calls {
            let result = AgentToolResult.error(toolCallId: call.id, toolName: call.name, message: reason)
            record(call, result); messages.append(.tool(reason, toolCallId: call.id))
        }
    }

    /// Runs one model/tool loop. Ordinary chat returns immediately without touching device services.
    public func run(context: String, onEvent: @escaping @MainActor (AssistantEvent) -> Void) async throws -> String {
        guard !used else { throw AssistantError.invalid("Agent 实例只能执行一次。") }
        used = true; observer = onEvent
        defer { observer = nil; jev?.cancel() }
        guard (1...128).contains(maxTurns) else { throw AssistantError.invalid("模型预算必须为 1–128 次。") }
        let packages = try AppSkillCatalog.packages(base: skills, pages: pages, workflows: flows, additions: additions)
        tools = suppliedTools + [HarnessSkillTool(catalog: SkillCatalog(packages: packages))]
        if jev != nil {
            tools.append(HarnessJevTool(run: { [weak self] task in
                guard let self else { throw AssistantError.cancelled }
                return try await self.delegate(task)
            }))
        }
        let executablePages = pages.filter { $0.state == "active" && !$0.requiresFreshSemanticCheck }
        if !executablePages.isEmpty { tools.append(HarnessPageTool(snapshot: executablePages, run: runPages)) }
        guard Set(tools.map(\.name)).count == tools.count else { throw AssistantError.invalid("工具注册名称重复。") }
        try appendContext(["prompt_revision": WorkflowPrompts.revision, "memory": context,
                           "available_skills": packages.map { ["name": $0.name, "description": $0.summary] }])
        var stage = AssistantModelStage.planning
        while turn < maxTurns {
            try check()
            let advertised = availableTools
            let response = try await request(stage: stage, definitions: definitions(advertised))
            if response.toolCalls.isEmpty {
                guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AssistantError.invalid("模型未返回工具调用或答复。") }
                if needsObservation { try await observeAfterInput(); stage = .verifying; continue }
                observer?(.modelStageChanged(.answering)); observer?(.programAnswer(response.text))
                return response.text
            }
            guard response.toolCalls.count <= 16, Set(response.toolCalls.map(\.id)).count == response.toolCalls.count,
                  response.toolCalls.allSatisfy({ !dispatchedIDs.contains($0.id) }) else {
                throw AssistantError.invalid("工具批次过大或调用 ID 重复；未执行本批操作。")
            }
            let calls = try response.toolCalls.map(call)
            dispatchedIDs.formUnion(calls.map(\.id))
            observer?(.toolCallsReceived(calls))
            // Preflight every call before any side effect. Correctable schema errors return correlated tool results.
            do {
                if calls.count > 1, calls.contains(where: { $0.name == "delegate_screen" }) {
                    throw WorkflowCorrectionRequired("delegate_screen 请单独调用，读取返回页面后再决定后续操作；本批尚未执行。")
                }
                for call in calls {
                    guard let tool = advertised.first(where: { $0.name == call.name }) else {
                        diagnostic("harness.validation field=tool rejected=true sent=false")
                        throw WorkflowCorrectionRequired("本批包含当前未开放的工具；先加载 ios-operation，再使用下一轮提供的工具。")
                    }
                    try validate(call.parameters.mapValues(\.value), tool: tool)
                }
            } catch let error as WorkflowCorrectionRequired {
                rejected(calls, reason: error.message)
                correctionCount += 1
                guard correctionCount <= 2 else { throw AssistantError.invalid("工具参数连续纠正失败：" + error.message) }
                stage = .correcting; continue
            }
            var correction: String?
            for (index, call) in calls.enumerated() {
                guard let tool = advertised.first(where: { $0.name == call.name }) else { throw AssistantError.invalid("工具注册在执行中改变。") }
                do {
                    let result = try await execute(call, tool: tool)
                    messages.append(.init(role: .tool, content: result.result, images: result.images, toolCallId: call.id))
                } catch let error as WorkflowCorrectionRequired {
                    correction = "输入未发送：" + error.message
                    if error.requiresObservation { needsObservation = true }
                } catch let error as PageWorkflowDeviation {
                    // The host supplies exact delivery progress. Never restart the completed prefix.
                    correction = error.localizedDescription + "只处理剩余步骤，不得重放已送达操作。"
                    needsObservation = true
                }
                if let correction {
                    messages.append(.tool(correction, toolCallId: call.id))
                    rejected(Array(calls.dropFirst(index + 1)), reason: "未执行：前一步需要纠正，请先核对新观察。")
                    break
                }
            }
            if let correction {
                correctionCount += 1
                guard correctionCount <= 2 else { throw AssistantError.unavailable("观察纠错预算已用完：" + correction) }
                stage = .correcting
            } else {
                correctionCount = 0
                stage = calls.contains { ["observe_screen", "screenshot", "run_page", "delegate_screen"].contains($0.name) } || needsObservation ? .verifying : .planning
            }
            if needsObservation { try await observeAfterInput() }
        }
        throw AssistantError.unavailable("任务达到模型调用预算，已停止；不会重放已发送操作。")
    }
}
