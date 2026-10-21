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
    var changedScreen = false
    var output: String? = nil
    var delayMilliseconds: UInt64 = 0
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
        if delayMilliseconds > 0 { try await Task.sleep(nanoseconds: delayMilliseconds * 1_000_000) }
        if changedScreen { throw WorkflowCorrectionRequired("目标移动；输入未发送", requiresObservation: true) }
        if correction { throw WorkflowCorrectionRequired("本帧需要视觉确认；输入未发送") }
        if let failure { return .error(toolCallId: context.callId, toolName: name, message: failure) }
        return .success(toolCallId: context.callId, toolName: name,
                        result: output ?? (name == "list_apps" ? "[{\"name\":\"Fixture\",\"bundle_id\":\"test.app\",\"version\":\"1\"}]" : "observed"))
    }
}
private func toolReply(_ request: ModelRequest, calls: [ModelToolCall]) -> ModelResponse {
    .init(text: "", finishReason: .toolCalls, toolCalls: calls, request: request, providerName: ScriptedModel.name)
}
private func finalReply(_ request: ModelRequest, _ text: String = "已核对") -> ModelResponse {
    .init(text: text, finishReason: .stop, request: request, providerName: ScriptedModel.name)
}
private func prepare(_ request: ModelRequest, app: Bool = true) -> ModelResponse {
    var calls = [ModelToolCall(id: "skill", name: "load_skill", arguments: "{\"name\":\"ios-operation\"}")]
    if app { calls.append(.init(id: "catalog", name: "list_apps", arguments: "{}")) }
    return toolReply(request, calls: calls)
}
private func launch(_ request: ModelRequest, id: String = "test.app") -> ModelResponse {
    toolReply(request, calls: [.init(id: "launch", name: "launch_app", arguments: "{\"bundle_id\":\"\(id)\",\"purpose\":\"打开\"}")])
}
@MainActor private func program(_ provider: ScriptedModel, trace: ProgramTrace, tools supplied: [ProgramTool]? = nil,
                                pages: [PageCapability] = [], maxTurns: Int = 8,
                                query: String = "帮我打开微信给测试联系人发哈哈", skills suppliedSkills: [SkillPackage]? = nil,
                                run: @escaping @Sendable ([PageCapabilityCall], String, String) async throws -> Void = { _, _, _ in }) throws -> HarnessAgentEngine {
    let skills = try suppliedSkills ?? [SkillPackage.make(documents: ["SKILL.md": "---\nname: ios-operation\ndescription: fixture\n---\nUse exact current evidence."]),
                  try SkillPackage.make(documents: ["SKILL.md": "---\nname: wechat\ndescription: 微信操作\n---\nVerify recipient and input before sending."])]
    let tools = supplied ?? ["list_apps", "launch_app", "observe_screen", "screenshot", "tap", "type_text"].map { ProgramTool(name: $0, trace: trace) }
    return HarnessAgentEngine(provider: provider, model: "fixture", query: query, images: [], history: [], maxTokens: 1000, maxTurns: maxTurns,
        tools: tools, skills: skills, workflows: [], pages: pages, runPages: run,
        receipt: { call, result in trace.add("receipt:" + call.name + (result.isError ? ":error" : ":ok")) }, diagnostic: { trace.add($0) }, cancelProvider: {})
}
struct ProgramEngineTests {
    @Test @MainActor func failedModelEmitsMeasuredTerminalInterval() async throws {
        let trace = ProgramTrace(), model = ScriptedModel { _, _ in
            Thread.sleep(forTimeInterval: 0.02)
            throw AssistantError.unavailable("fixture model failure")
        }
        var elapsed: TimeInterval?, completed = false
        do {
            _ = try await program(model, trace: trace).run(context: "") { event in
                if case .llmCallFailed(let turn, let seconds) = event { #expect(turn == 1); elapsed = seconds }
                if case .llmCallCompleted = event { completed = true }
            }
            Issue.record("Expected model failure")
        } catch { #expect(error.localizedDescription == "fixture model failure") }
        #expect(try #require(elapsed) >= 0.02)
        #expect(!completed)
    }

    @Test @MainActor func measuresModelAndToolIntervalsIncludingFailedTools() async throws {
        let trace = ProgramTrace(), model = ScriptedModel { request, index in
            Thread.sleep(forTimeInterval: 0.02)
            if index == 0 { return prepare(request, app: false) }
            return toolReply(request, calls: [.init(id: "ocr-timed", name: "observe_screen", arguments: "{}")])
        }
        let tools = [ProgramTool(name: "observe_screen", trace: trace, failure: "capture failed", delayMilliseconds: 20)]
        var responses: [AssistantResponse] = [], results: [String: AssistantToolResult] = [:]
        do {
            _ = try await program(model, trace: trace, tools: tools).run(context: "") { event in
                if case .llmCallCompleted(_, let response) = event { responses.append(response) }
                if case .toolExecutionFinished(let call, let result) = event { results[call.id] = result }
            }
            Issue.record("Expected actual capture failure")
        } catch { #expect(error.localizedDescription == "capture failed") }
        #expect(responses.count == 2)
        for response in responses { #expect(try #require(response.durationSeconds) >= 0.02) }
        #expect(try #require(results["skill"]?.durationSeconds) >= 0)
        #expect(try #require(results["ocr-timed"]?.durationSeconds) >= 0.02)
        #expect(results["ocr-timed"]?.isError == true)
        #expect(trace.read().filter { $0.contains("harness.model.first_event") && $0.contains("ms=") }.count == 2)
        #expect(trace.read().contains { $0.contains("harness.tool.failed") && $0.contains("call=ocr-timed") && $0.contains("ms=") })
    }
    @Test @MainActor func rejectedCallsDoNotPretendTheyExecutedForZeroSeconds() async throws {
        let trace = ProgramTrace(), model = ScriptedModel { request, index in
            if index == 0 { return prepare(request) }
            if index == 1 { return launch(request, id: "not.installed") }
            return finalReply(request)
        }
        var rejected: AssistantToolResult?
        _ = try await program(model, trace: trace).run(context: "") { event in
            if case .toolExecutionFinished(let call, let result) = event, call.id == "launch" { rejected = result }
        }
        #expect(rejected?.isError == true)
        #expect(rejected?.durationSeconds == nil)
        #expect(!trace.read().contains("launch_app"))
    }

    @Test @MainActor func chatIsOneModelCallWithoutRouteOrDevice() async throws {
        let trace = ProgramTrace(), model = ScriptedModel { request, index in
            #expect(index == 0)
            #expect(Set(request.tools.map(\.name)) == ["load_skill", "list_apps"])
            #expect(!request.tools.contains { $0.name == "route_task" })
            return finalReply(request, "你好")
        }
        #expect(try await program(model, trace: trace).run(context: "", onEvent: { _ in }) == "你好")
        #expect(!trace.read().contains("list_apps"))
        #expect(model.history().count == 1)
    }
    @Test @MainActor func chineseWeChatUsesCatalogThenDirectToolsAndWholeText() async throws {
        let trace = ProgramTrace(), model = ScriptedModel { request, index in
            if index == 0 { return prepare(request) }
            if index == 1 {
                #expect(request.tools.contains { $0.name == "type_text" })
                #expect(request.messages.contains { $0.role == .tool && $0.toolCallId == "catalog" && $0.content.contains("WeChat") })
                return toolReply(request, calls: [.init(id: "wechat", name: "load_skill", arguments: "{\"name\":\"wechat\"}"),
                    .init(id: "launch", name: "launch_app", arguments: "{\"bundle_id\":\"com.tencent.xin\",\"purpose\":\"微信\"}")])
            }
            if index == 2 {
                #expect(request.messages.contains { $0.content.contains("Verify recipient") })
                return toolReply(request, calls: [.init(id: "input", name: "type_text", arguments: "{\"text\":\"哈哈\",\"purpose\":\"输入消息\"}")])
            }
            #expect(index == 3)
            #expect(trace.read().filter { $0 == "observe_screen" }.count == 2)
            return finalReply(request)
        }
        let tools = ["list_apps", "launch_app", "observe_screen", "type_text"].map { ProgramTool(name: $0, trace: trace,
            output: $0 == "list_apps" ? "[{\"name\":\"WeChat\",\"bundle_id\":\"com.tencent.xin\"}]" : nil) }
        _ = try await program(model, trace: trace, tools: tools).run(context: "", onEvent: { _ in })
        #expect(trace.read().filter { $0 == "launch_app" }.count == 1)
        #expect(trace.read().filter { $0 == "type_text" }.count == 1)
    }
    @Test @MainActor func currentScreenTaskDoesNotRequireCatalogOrLaunch() async throws {
        let trace = ProgramTrace(), model = ScriptedModel { request, index in
            if index == 0 { return prepare(request, app: false) }
            if index == 1 { return toolReply(request, calls: [.init(id: "ocr", name: "observe_screen", arguments: "{}")]) }
            return finalReply(request, "已读取")
        }
        _ = try await program(model, trace: trace).run(context: "", onEvent: { _ in })
        #expect(trace.read().filter { $0 == "observe_screen" }.count == 1)
        #expect(!trace.read().contains("list_apps") && !trace.read().contains("launch_app"))
    }
    /// Use the shipped shared skill, no app-specific skill and no learned records; tools still execute and observe normally.
    @Test @MainActor func appWithoutDedicatedSkillUsesSharedToolsAndFreshObservations() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tapito/BuiltinSkills/ios-operation")
        let entrypoint = try String(contentsOf: root.appendingPathComponent("SKILL.md"), encoding: .utf8)
        let skill = try SkillPackage.make(documents: ["SKILL.md": entrypoint])
        let trace = ProgramTrace(), model = ScriptedModel { request, index in
            switch index {
            case 0:
                let host = try #require(request.messages.last?.content.data(using: .utf8))
                let context = try #require(JSONSerialization.jsonObject(with: host) as? [String: Any])
                let values = try #require(context["host_context"] as? [String: Any])
                let skills = try #require(values["available_skills"] as? [[String: String]])
                #expect(skills.map { $0["name"] } == ["ios-operation"])
                return prepare(request)
            case 1:
                #expect(Set(["launch_app", "observe_screen", "screenshot", "tap", "type_text"]).isSubset(of: Set(request.tools.map(\.name))))
                #expect(request.messages.contains { $0.toolCallId == "skill" && $0.content.contains("App coverage") })
                return launch(request, id: "fixture.unskilled.douyin")
            case 2:
                #expect(trace.read().filter { $0 == "observe_screen" }.count == 1)
                return toolReply(request, calls: [.init(id: "view-unfamiliar", name: "screenshot", arguments: "{}")])
            case 3:
                return toolReply(request, calls: [.init(id: "focus-unfamiliar", name: "tap", arguments: "{\"x\":30,\"y\":40,\"purpose\":\"聚焦已观察到的输入框\"}")])
            case 4:
                #expect(trace.read().filter { $0 == "observe_screen" }.count == 2)
                return toolReply(request, calls: [.init(id: "input-unfamiliar", name: "type_text", arguments: "{\"text\":\"哈哈哈\",\"purpose\":\"填写用户指定内容\"}")])
            default:
                #expect(index == 5)
                #expect(trace.read().filter { $0 == "observe_screen" }.count == 3)
                return finalReply(request, "已核验测试输入")
            }
        }
        let tools = ["list_apps", "launch_app", "observe_screen", "screenshot", "tap", "type_text"].map {
            ProgramTool(name: $0, trace: trace, output: $0 == "list_apps" ? "[{\"name\":\"抖音（测试目录）\",\"bundle_id\":\"fixture.unskilled.douyin\"}]" : nil)
        }
        let engine = try program(model, trace: trace, tools: tools,
            query: "打开抖音，在评论框填写哈哈哈", skills: [skill])
        #expect(try await engine.run(context: "", onEvent: { _ in }) == "已核验测试输入")
        let deviceNames = Set(tools.map(\.name))
        #expect(trace.read().filter { deviceNames.contains($0) } == ["list_apps", "launch_app", "observe_screen", "screenshot", "tap", "observe_screen", "type_text", "observe_screen"])
        #expect(trace.read().filter { $0.hasPrefix("harness.skill.loaded") } == ["harness.skill.loaded name=ios-operation"])
    }
    @Test @MainActor func badLaterParameterPreventsWholeBatchThenModelCorrects() async throws {
        let trace = ProgramTrace(), model = ScriptedModel { request, index in
            if index == 0 { return prepare(request) }
            if index == 1 { return toolReply(request, calls: [
                .init(id: "valid", name: "tap", arguments: "{\"x\":30,\"y\":40,\"purpose\":\"搜索\"}"),
                .init(id: "invalid", name: "type_text", arguments: "{\"text\":\"哈哈\"}")]) }
            if index == 2 {
                #expect(!trace.read().contains("tap") && !trace.read().contains("type_text"))
                #expect(request.messages.contains { $0.toolCallId == "invalid" && $0.content.contains("purpose") })
                return toolReply(request, calls: [.init(id: "fixed", name: "type_text", arguments: "{\"text\":\"哈哈\",\"purpose\":\"输入\"}")])
            }
            return finalReply(request)
        }
        _ = try await program(model, trace: trace).run(context: "", onEvent: { _ in })
        #expect(trace.read().filter { $0 == "type_text" }.count == 1)
        #expect(trace.read().contains { $0.contains("field=purpose") && $0.contains("sent=false") })
    }
    @Test @MainActor func invalidAppIdentityCanBeCorrectedWithoutAnyLaunch() async throws {
        let trace = ProgramTrace(), model = ScriptedModel { request, index in
            if index == 0 { return prepare(request) }
            if index == 1 { return launch(request, id: "invented") }
            if index == 2 {
                #expect(!trace.read().contains("launch_app"))
                #expect(request.messages.contains { $0.toolCallId == "launch" && $0.content.contains("bundle_id") })
            }
            return finalReply(request, "目标未安装")
        }
        _ = try await program(model, trace: trace).run(context: "", onEvent: { _ in })
        #expect(!trace.read().contains("launch_app"))
    }
    @Test @MainActor func unknownOutcomeRemainsTerminalAndCannotBeRetried() async throws {
        let trace = ProgramTrace(), model = ScriptedModel { request, index in
            if index == 0 { return prepare(request) }
            #expect(index == 1)
            return toolReply(request, calls: [.init(id: "tap", name: "tap", arguments: "{\"x\":30,\"y\":40,\"purpose\":\"发送\"}"),
                .init(id: "input", name: "type_text", arguments: "{\"text\":\"不会执行\",\"purpose\":\"输入\"}")])
        }
        let tools = ["list_apps", "observe_screen", "tap", "type_text"].map { ProgramTool(name: $0, trace: trace, failure: $0 == "tap" ? "结果未知" : nil) }
        await #expect(throws: AssistantError.self) { _ = try await program(model, trace: trace, tools: tools).run(context: "", onEvent: { _ in }) }
        #expect(trace.read().filter { $0 == "tap" }.count == 1)
        #expect(!trace.read().contains("type_text"))
        #expect(trace.read().contains("receipt:tap:error"))
        #expect(model.history().count == 2)
    }
    @Test @MainActor func changedTargetSuppliesNewOCRBeforeModelDecisionWithoutReplayingBatch() async throws {
        let trace = ProgramTrace(), model = ScriptedModel { request, index in
            if index == 0 { return prepare(request, app: false) }
            if index == 1 {
                return toolReply(request, calls: [
                    .init(id: "stale-tap", name: "tap", arguments: "{\"x\":765,\"y\":1159,\"purpose\":\"更多热搜\"}"),
                    .init(id: "unsent-text", name: "type_text", arguments: "{\"text\":\"test\",\"purpose\":\"must not execute\"}")])
            }
            #expect(request.messages.contains { $0.content.contains("fresh-frame-target-y-938") })
            #expect(request.messages.contains { $0.toolCallId == "unsent-text" })
            #expect(trace.read().filter { $0 == "tap" }.count == 1)
            #expect(!trace.read().contains("type_text"))
            return finalReply(request, "已收到新画面")
        }
        let tools = [ProgramTool(name: "tap", trace: trace, changedScreen: true),
                     ProgramTool(name: "type_text", trace: trace),
                     ProgramTool(name: "observe_screen", trace: trace, output: "fresh-frame-target-y-938")]
        _ = try await program(model, trace: trace, tools: tools).run(context: "", onEvent: { _ in })
        #expect(trace.read().filter { $0 == "observe_screen" }.count == 1)
    }
    @Test @MainActor func typedUnsentCorrectionSkipsRestAndCorrelatesEveryCall() async throws {
        let trace = ProgramTrace(), model = ScriptedModel { request, index in
            if index == 0 { return prepare(request) }
            if index == 1 { return toolReply(request, calls: [.init(id: "tap", name: "tap", arguments: "{\"x\":30,\"y\":40,\"purpose\":\"搜索\"}"),
                .init(id: "input", name: "type_text", arguments: "{\"text\":\"内容\",\"purpose\":\"输入\"}")]) }
            #expect(request.messages.contains { $0.role == .tool && $0.toolCallId == "tap" && $0.content.contains("未发送") })
            #expect(request.messages.contains { $0.role == .tool && $0.toolCallId == "input" && $0.content.contains("未执行") })
            return finalReply(request, "需要确认目标")
        }
        let tools = ["list_apps", "tap", "type_text"].map { ProgramTool(name: $0, trace: trace, correction: $0 == "tap") }
        _ = try await program(model, trace: trace, tools: tools).run(context: "", onEvent: { _ in })
        #expect(!trace.read().contains("type_text"))
    }
    @Test @MainActor func malformedCatalogIsTerminalNotAnAppSelectionProblem() async throws {
        for directory in ["invalid", "[{\"bundle_id\":\"test.app\"}]", "[{\"name\":\"A\",\"bundle_id\":\"same\"},{\"name\":\"B\",\"bundle_id\":\"same\"}]"] {
            let trace = ProgramTrace(), model = ScriptedModel { request, index in
                #expect(index == 0); return prepare(request)
            }
            await #expect(throws: (any Error).self) {
                _ = try await program(model, trace: trace, tools: [ProgramTool(name: "list_apps", trace: trace, output: directory)]).run(context: "", onEvent: { _ in })
            }
            #expect(model.history().count == 1)
        }
    }
    @Test @MainActor func transportFailureDoesNotRetryCatalog() async throws {
        let trace = ProgramTrace(), model = ScriptedModel { request, index in
            #expect(index == 0); return prepare(request)
        }
        await #expect(throws: AssistantError.self) {
            _ = try await program(model, trace: trace, tools: [ProgramTool(name: "list_apps", trace: trace, failure: "连接失败")]).run(context: "", onEvent: { _ in })
        }
        #expect(trace.read().filter { $0 == "list_apps" }.count == 1)
    }
    @Test @MainActor func truncatedToolResponseNeverExecutes() async throws {
        let trace = ProgramTrace(), model = ScriptedModel { request, _ in
            .init(text: "partial", finishReason: .length, toolCalls: [.init(id: "x", name: "list_apps", arguments: "{}")], request: request, providerName: ScriptedModel.name)
        }
        await #expect(throws: AssistantError.self) { _ = try await program(model, trace: trace).run(context: "", onEvent: { _ in }) }
        #expect(!trace.read().contains("list_apps"))
    }
    @Test @MainActor func repeatedCallIDNeverReplays() async throws {
        let trace = ProgramTrace(), model = ScriptedModel { request, _ in prepare(request) }
        await #expect(throws: AssistantError.self) { _ = try await program(model, trace: trace).run(context: "", onEvent: { _ in }) }
        #expect(trace.read().filter { $0 == "list_apps" }.count == 1)
    }
    @Test @MainActor func cancellationAfterReceiptPreventsNextInput() async throws {
        let trace = ProgramTrace(), model = ScriptedModel { request, index in index == 0 ? prepare(request) : launch(request) }
        let engine = try program(model, trace: trace)
        await #expect(throws: AssistantError.self) {
            _ = try await engine.run(context: "", onEvent: { event in
                if case .toolExecutionFinished(let call, _) = event, call.name == "list_apps" { engine.cancel() }
            })
        }
        #expect(!trace.read().contains("launch_app"))
    }
    @Test @MainActor func publishedPageIsToolAndHasNoMandatoryRoutingEnvelope() async throws {
        let item = capability(), trace = ProgramTrace(), model = ScriptedModel { request, index in
            if index == 0 { return prepare(request) }
            if index == 1 {
                #expect(request.tools.contains { $0.name == "run_page" })
                return toolReply(request, calls: [.init(id: "page", name: "run_page", arguments: "{\"id\":\"\(item.id)\",\"revision\":\"\(item.revision)\"}")])
            }
            return finalReply(request)
        }
        _ = try await program(model, trace: trace, pages: [item]) { calls, app, _ in
            #expect(calls.count == 1 && calls[0].id == item.id && app == "test.app")
            trace.add("page_sequence")
        }.run(context: "", onEvent: { _ in })
        #expect(trace.read().contains("page_sequence"))
        #expect(!trace.read().contains("observe_screen"))
    }
    @Test @MainActor func unknownPageCannotExecuteOrLaunch() async throws {
        let item = capability(), trace = ProgramTrace(), model = ScriptedModel { request, index in
            if index == 0 { return prepare(request) }
            if index == 1 { return toolReply(request, calls: [.init(id: "page", name: "run_page", arguments: "{\"id\":\"\(UUID())\",\"revision\":\"\(UUID())\"}")]) }
            return finalReply(request, "无匹配页面")
        }
        _ = try await program(model, trace: trace, pages: [item]) { _, _, _ in trace.add("page_sequence") }.run(context: "", onEvent: { _ in })
        #expect(!trace.read().contains("page_sequence") && !trace.read().contains("launch_app"))
    }
    @Test func reviewedLearningBecomesSameAppSkillReferenceWithoutPixels() throws {
        let base = try SkillPackage.make(documents: ["SKILL.md": "---\nname: app-test.app\ndescription: fixture\n---\nBase skill."])
        let item = capability(), packages = try AppSkillCatalog.packages(base: [base], pages: [item], workflows: [], additions: [])
        #expect(packages.count == 1 && packages[0].id == base.id)
        #expect(packages[0].documents["SKILL.md"]!.contains("learned-operations.md"))
        let text = packages[0].documents["references/learned-operations.md"]!
        #expect(text.contains(item.id.uuidString) && text.contains("bounds") && !text.contains("patch"))
        var candidate = item; candidate.state = "candidate"
        #expect(try AppSkillCatalog.packages(base: [], pages: [candidate], workflows: [], additions: []).isEmpty)
    }
    @Test func pageAnalysisDoesNotReceivePersonalInputOrPixelPatches() async throws {
        let personal = "我的私密偏好原话", evidence = transition(patches: true)
        let memoryModel = ScriptedModel { request, _ in
            #expect(request.messages.last?.content.contains(personal) == true)
            return toolReply(request, calls: [.init(id: "m6", name: "store_memory_proposals", arguments: "{\"memories\":[]}")])
        }
        let pageModel = ScriptedModel { request, _ in
            #expect(!request.messages.contains { $0.content.contains(personal) || $0.content.contains("patch") })
            return toolReply(request, calls: [.init(id: "m7", name: "store_page_candidates", arguments: "{\"annotations\":[]}")])
        }
        let job = AssistantLearningJob(id: evidence.runID, workspaceEpoch: UUID(), userText: personal, providerID: UUID(), providerScope: "fixture-scope", model: "fixture", transitions: [evidence], state: "pending", message: nil)
        _ = try await KnowledgeAnalyzer.analyze(job: job, memories: [], provider: memoryModel, pageProvider: pageModel, maxTokens: 1000)
    }
}
