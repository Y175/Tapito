import Foundation
import Testing
import SwiftAgentKit
import ProviderCore
@testable import TapitoAgentCore
import TapitoAgentSwiftAgentKit

private final class ProgramTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.withLock { values.append(value) } }
    func read() -> [String] { lock.withLock { values } }
}
private final class ScriptedModel: ModelProvider, @unchecked Sendable {
    static let name = "workflow-fixture"
    let configuration = ProviderConfiguration(name: name, baseURL: URL(string: "https://fixture.invalid")!)
    private let lock = NSLock()
    private var requests: [ModelRequest] = []
    let reply: @Sendable (ModelRequest, Int) throws -> ModelResponse
    init(_ reply: @escaping @Sendable (ModelRequest, Int) throws -> ModelResponse) { self.reply = reply }
    func history() -> [ModelRequest] { lock.withLock { requests } }
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        let index = lock.withLock { let index = requests.count; requests.append(request); return index }
        return try reply(request, index)
    }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { stream in
            let task = Task {
                do { stream.yield(.terminal(try await complete(request))); stream.finish() }
                catch { stream.finish(throwing: error) }
            }
            stream.onTermination = { _ in task.cancel() }
        }
    }
}
private struct ProgramTool: AgentTool {
    let name: String
    let trace: ProgramTrace
    var failure: String? = nil
    var correction = false
    var description: String { name }
    var parameters: ToolParameters {
        switch name {
        case "launch_app": return .init(properties: ["bundle_id": .init(type: "string", description: "App"), "purpose": .init(type: "string", description: "Purpose")], required: ["bundle_id", "purpose"])
        case "tap": return .init(properties: ["x": .init(type: "integer", description: "x"), "y": .init(type: "integer", description: "y"), "purpose": .init(type: "string", description: "purpose")], required: ["x", "y", "purpose"])
        case "type_text": return .init(properties: ["text": .init(type: "string", description: "text"), "purpose": .init(type: "string", description: "purpose")], required: ["text", "purpose"])
        default: return .empty
        }
    }
    func execute(parameters: [String: Any]) async throws -> AgentToolResult { throw AssistantError.invalid("Context required") }
    func execute(context: ToolContext) async throws -> AgentToolResult {
        trace.add(name)
        if correction { throw WorkflowCorrectionRequired("本帧需要视觉确认；输入未发送") }
        if let failure { return .error(toolCallId: context.callId, toolName: name, message: failure) }
        return .success(toolCallId: context.callId, toolName: name,
                        result: name == "list_apps" ? "[{\"name\":\"Fixture\",\"bundle_id\":\"test.app\",\"version\":\"1\"}]" : "observed")
    }
}
private func route(_ request: ModelRequest, kind: String = "device_task", pages: [PageCapabilityCall] = [], summary: Bool = false, current: Bool = false) throws -> ModelResponse {
    let value: [String: Any] = ["kind": kind, "target_mode": kind == "conversation" ? "none" : current ? "current_screen" : "app", "app_bundle_id": current ? NSNull() : "test.app", "app_name": current ? NSNull() : "Fixture", "skill_ids": [],
        "flow_id": NSNull(), "flow_revision": NSNull(), "texts": [], "requires_summary": summary,
        "completion_kind": kind == "conversation" ? "conversation" : "page_transition", "question": NSNull(),
        "page_calls": try pageCallsJSON(pages)]
    return .init(text: "", finishReason: .toolCalls,
        toolCalls: [.init(id: "route", name: "route_task", arguments: String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))],
        request: request, providerName: ScriptedModel.name)
}
private func pageCallsJSON(_ values: [PageCapabilityCall]) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(values))
}
private func toolReply(_ request: ModelRequest, calls: [ModelToolCall]) -> ModelResponse {
    .init(text: "", finishReason: .toolCalls, toolCalls: calls, request: request, providerName: ScriptedModel.name)
}
private func finalReply(_ request: ModelRequest, _ text: String = "已核对") -> ModelResponse {
    .init(text: text, finishReason: .stop, request: request, providerName: ScriptedModel.name)
}
@MainActor private func program(_ provider: ScriptedModel, trace: ProgramTrace, tools supplied: [ProgramTool]? = nil,
                                pages: [PageCapability] = [], run: @escaping @Sendable ([PageCapabilityCall], String, String) async throws -> Void = { _, _, _ in }) throws -> WorkflowAgentEngine {
    let skills = [try SkillPackage.make(documents: ["SKILL.md": "---\nname: ios-operation\ndescription: fixture\n---\nUse exact current evidence."])]
    let tools = supplied ?? ["list_apps", "launch_app", "observe_screen", "screenshot", "tap", "type_text"].map { ProgramTool(name: $0, trace: trace) }
    return WorkflowAgentEngine(provider: provider, model: "fixture", query: "打开搜索", images: [], history: [], maxTokens: 1000, maxTurns: 8,
        tools: tools, skills: skills, workflows: [], pages: pages, runPages: run,
        receipt: { call, result in trace.add("receipt:" + call.name + (result.isError ? ":error" : ":ok")) }, diagnostic: { _ in }, cancelProvider: {})
}
struct ProgramEngineTests {
    @Test @MainActor func ordinaryConversationDoesNotTouchDevice() async throws {
        let trace = ProgramTrace(), model = ScriptedModel { request, index in
            index == 0 ? try route(request, kind: "conversation") : finalReply(request, "你好")
        }
        let engine = try program(model, trace: trace)
        #expect(try await engine.run(context: "", onEvent: { _ in }) == "你好")
        #expect(trace.read().isEmpty)
        #expect(model.history().count == 2)
    }
    @Test @MainActor func publishedChainUsesOnlyRoutingModelAndProgramAnswer() async throws {
        let item = capability(), call = PageCapabilityCall(id: item.id, revision: item.revision), trace = ProgramTrace()
        let model = ScriptedModel { request, index in
            #expect(index == 0)
            return try route(request, pages: [call])
        }
        let engine = try program(model, trace: trace, pages: [item]) { calls, app, _ in
            #expect(calls.count == 1 && calls[0].id == item.id && app == "test.app")
            trace.add("page_sequence")
        }
        var modelCalls = 0, directAnswers = 0
        _ = try await engine.run(context: "", onEvent: { event in
            if case .llmCallStarted = event { modelCalls += 1 }
            if case .programAnswer = event { directAnswers += 1 }
        })
        #expect(modelCalls == 1 && directAnswers == 1)
        #expect(trace.read() == ["list_apps", "receipt:list_apps:ok", "launch_app", "receipt:launch_app:ok", "page_sequence"])
    }
    @Test @MainActor func fixedPreparationAndObservationFeedActualToolCalls() async throws {
        let trace = ProgramTrace(), model = ScriptedModel { request, index in
            if index == 0 { return try route(request) }
            if index == 1 {
                #expect(trace.read().filter { $0 == "observe_screen" }.count == 1)
                return toolReply(request, calls: [.init(id: "tap1", name: "tap", arguments: "{\"x\":30,\"y\":40,\"purpose\":\"搜索\"}")])
            }
            #expect(request.messages.contains { $0.toolCallId == "tap1" && $0.role == .tool })
            #expect(trace.read().filter { $0 == "observe_screen" }.count == 2)
            #expect(trace.read().contains("receipt:tap:ok"))
            return finalReply(request)
        }
        _ = try await program(model, trace: trace).run(context: "", onEvent: { _ in })
        #expect(model.history().count == 3)
        #expect(trace.read().filter { $0 == "launch_app" }.count == 1)
        let requests = model.history()
        for index in 1..<requests.count {
            let before = requests[index - 1].messages, after = requests[index].messages
            #expect(after.count > before.count)
            for (a, b) in zip(before, after) {
                #expect(a.role == b.role && a.content == b.content && a.toolCallId == b.toolCallId && a.toolCalls == b.toolCalls)
            }
        }
    }
    @Test @MainActor func invalidLaterToolPreventsEarlierValidInput() async throws {
        let trace = ProgramTrace(), model = ScriptedModel { request, index in
            if index == 0 { return try route(request) }
            return toolReply(request, calls: [.init(id: "valid", name: "tap", arguments: "{\"x\":30,\"y\":40,\"purpose\":\"搜索\"}"),
                                              .init(id: "bad", name: "shell", arguments: "{}")])
        }
        await #expect(throws: AssistantError.self) { _ = try await program(model, trace: trace).run(context: "", onEvent: { _ in }) }
        #expect(!trace.read().contains("tap"))
    }
    @Test @MainActor func unknownOutcomeIsTerminalAndReceiptIsPreserved() async throws {
        let trace = ProgramTrace()
        let model = ScriptedModel { request, index in
            if index == 0 { return try route(request) }
            #expect(index == 1)
            return toolReply(request, calls: [.init(id: "tap1", name: "tap", arguments: "{\"x\":30,\"y\":40,\"purpose\":\"搜索\"}")])
        }
        let tools = ["list_apps", "launch_app", "observe_screen", "tap"].map { ProgramTool(name: $0, trace: trace, failure: $0 == "tap" ? "结果未知" : nil) }
        await #expect(throws: AssistantError.self) { _ = try await program(model, trace: trace, tools: tools).run(context: "", onEvent: { _ in }) }
        #expect(trace.read().filter { $0 == "tap" }.count == 1)
        #expect(trace.read().contains("receipt:tap:error"))
    }
    @Test @MainActor func typedUnsentCorrectionSkipsRemainingBatchAndCorrelatesResults() async throws {
        let trace = ProgramTrace(), model = ScriptedModel { request, index in
            if index == 0 { return try route(request) }
            if index == 1 {
                return toolReply(request, calls: [.init(id: "tap1", name: "tap", arguments: "{\"x\":30,\"y\":40,\"purpose\":\"搜索\"}"),
                    .init(id: "input1", name: "type_text", arguments: "{\"text\":\"内容\",\"purpose\":\"输入\"}")])
            }
            #expect(request.messages.contains { $0.role == .tool && $0.toolCallId == "input1" && $0.content.contains("未执行") })
            #expect(request.messages.last?.content.contains("M4") == true)
            return finalReply(request, "当前目标需要确认")
        }
        let tools = ["list_apps", "launch_app", "observe_screen", "tap", "type_text"].map { ProgramTool(name: $0, trace: trace, correction: $0 == "tap") }
        _ = try await program(model, trace: trace, tools: tools).run(context: "", onEvent: { _ in })
        #expect(!trace.read().contains("type_text"))
        #expect(trace.read().contains("receipt:tap:error"))
    }
    @Test @MainActor func truncatedRouteCannotStartAnyDeviceAction() async throws {
        let trace = ProgramTrace(), model = ScriptedModel { request, _ in
            .init(text: "partial", finishReason: .length, request: request, providerName: ScriptedModel.name)
        }
        await #expect(throws: AssistantError.self) { _ = try await program(model, trace: trace).run(context: "", onEvent: { _ in }) }
        #expect(trace.read().isEmpty)
    }
    @Test @MainActor func currentScreenReadDoesNotLaunchOrRequireAnAppIdentity() async throws {
        let trace = ProgramTrace(), model = ScriptedModel { request, index in
            index == 0 ? try route(request, current: true) : finalReply(request, "已读取当前画面")
        }
        _ = try await program(model, trace: trace).run(context: "", onEvent: { _ in })
        #expect(trace.read() == ["observe_screen", "receipt:observe_screen:ok"])
    }
    @Test @MainActor func invalidCapabilityCannotEvenLaunchTheApp() async throws {
        let trace = ProgramTrace(), model = ScriptedModel { request, _ in
            try route(request, pages: [.init(id: UUID(), revision: UUID())])
        }
        await #expect(throws: AssistantError.self) { _ = try await program(model, trace: trace).run(context: "", onEvent: { _ in }) }
        #expect(!trace.read().contains("launch_app"))
    }
    @Test @MainActor func unregisteredAppInLaterBatchPreventsFirstTap() async throws {
        let trace = ProgramTrace(), model = ScriptedModel { request, index in
            if index == 0 { return try route(request) }
            return toolReply(request, calls: [.init(id: "tap", name: "tap", arguments: "{\"x\":30,\"y\":40,\"purpose\":\"搜索\"}"),
                .init(id: "launch", name: "launch_app", arguments: "{\"bundle_id\":\"not.installed\",\"purpose\":\"打开\"}")])
        }
        await #expect(throws: AssistantError.self) { _ = try await program(model, trace: trace).run(context: "", onEvent: { _ in }) }
        #expect(!trace.read().contains("tap"))
    }
    @Test func pageAnalysisDoesNotReceivePersonalInputOrPixelPatches() async throws {
        let personal = "我的私密偏好原话", evidence = transition(patches: true)
        let memoryModel = ScriptedModel { request, _ in
            #expect(request.messages.last?.content.contains(personal) == true)
            return toolReply(request, calls: [.init(id: "m6", name: "store_memory_proposals", arguments: "{\"memories\":[]}")])
        }
        let pageModel = ScriptedModel { request, _ in
            #expect(!request.messages.contains { $0.content.contains(personal) || $0.content.contains("patch") })
            #expect(request.messages.last?.content.contains("搜索") == true)
            return toolReply(request, calls: [.init(id: "m7", name: "store_page_candidates", arguments: "{\"annotations\":[]}")])
        }
        let job = AssistantLearningJob(id: evidence.runID, workspaceEpoch: UUID(), userText: personal, providerID: UUID(), providerScope: "fixture-scope", model: "fixture",
                                      transitions: [evidence], state: "pending", message: nil)
        _ = try await KnowledgeAnalyzer.analyze(job: job, memories: [], provider: memoryModel, pageProvider: pageModel, maxTokens: 1000)
        #expect(memoryModel.history().count == 1 && pageModel.history().count == 1)
    }
}
