import Foundation
import Testing
import SwiftAgentKit
import ProviderCore
@testable import TapitoAgentCore
import TapitoAgentSwiftAgentKit

@MainActor final class DelegationJev: JevDecisionProviding {
    var choices: [(String, String?)]
    var requests: [([String: AssistantValue], [JevQuestion])] = []
    var cancelled = false
    var beforeReply: (() -> Void)?
    init(_ choices: [(String, String?)]) { self.choices = choices }
    func cancel() { cancelled = true }
    func evaluate(state: [String: AssistantValue], questions: [JevQuestion]) async throws -> JevEvaluation {
        requests.append((state, questions)); beforeReply?()
        guard !choices.isEmpty else { throw AssistantError.invalid("Unexpected Jev inference") }
        let (operation, target) = choices.removeFirst()
        var answers: [String: Any] = ["operation": ["type": "choice", "choice": operation,
            "probabilities": [operation: 0.01], "confidence": 0.001]]
        if let target {
            answers["tap_target"] = ["type": "choice", "choice": target, "probabilities": [target: 0.01], "confidence": 0.001]
        } else {
            answers["tap_target"] = ["type": "unused-invalid-head"]
        }
        return try JevEvaluation(data: JSONSerialization.data(withJSONObject: [
            "model": "fixture-jev", "answers": answers, "usage": ["input_tokens": 20, "output_tokens": 3]]))
    }
}

func delegationScreen(_ frame: String, _ text: String = "更多热搜", next: Int? = nil, id: String = "target") throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: [
        "frame_id": frame, "width": 1206, "height": 2622,
        "candidates": [["id": id, "text": text, "confidence": 0.01,
                        "bounds": ["x": 640, "y": 900, "width": 180, "height": 60]]],
        "next_offset": next as Any? ?? NSNull()
    ]), as: UTF8.self)
}

struct JevDelegationTests {
    @Test @MainActor func doneHandsObservationBackWithoutAnsweringOrTouchingDevice() async throws {
        let client = DelegationJev([("subgoal_done", nil)])
        var calls: [String] = []
        let executor = JevScreenExecutor(evaluate: client.evaluate, execute: { call in
            calls.append(call.name); return .init(result: try delegationScreen("home", "普通推荐内容"), isError: false)
        }, check: {}, diagnostic: { _ in })
        let result = try await executor.run(JevDelegation(goal: "进入榜单", completion: "可见排名"))
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        #expect(object["status"] as? String == "subgoal_done")
        #expect(object["overall_success"] as? Bool == false)
        #expect(object["answer"] == nil)
        #expect(calls == ["observe_screen"])
        #expect(client.requests.count == 1)
    }

    @Test @MainActor func lowConfidenceTapUsesSameRequestAndAllOCRPages() async throws {
        let client = DelegationJev([("tap", "second"), ("subgoal_done", nil)])
        var calls: [AssistantToolCall] = []
        let executor = JevScreenExecutor(evaluate: client.evaluate, execute: { call in
            calls.append(call)
            if call.name == "tap_text" { return .init(result: "delivered", isError: false) }
            if call.parameters["offset"] != nil { return .init(result: try delegationScreen("first", next: nil, id: "second"), isError: false) }
            return .init(result: try delegationScreen("after", "1 热搜条目"), isError: false)
        }, check: {}, diagnostic: { _ in })
        let result = try await executor.run(JevDelegation(goal: "查看完整榜单", completion: "可见榜单"),
            initialObservation: delegationScreen("first", next: 1))
        #expect(client.requests.first?.1.map(\.id) == ["operation", "tap_target"])
        #expect(client.requests.first?.1.last?.options.map(\.id) == ["target", "second"])
        let tap = try #require(calls.first { $0.name == "tap_text" })
        #expect(tap.parameters["frame_id"] == .string("first"))
        #expect(tap.parameters["candidate_id"] == .string("second"))
        #expect(result.contains("after"))
        #expect(calls.filter { $0.name == "tap_text" }.count == 1)
    }

    @Test @MainActor func inputIsExactAndConsumedOnceThenReturnsForAnotherField() async throws {
        let client = DelegationJev([("type", nil), ("type", nil)])
        var texts: [AssistantValue] = []
        let executor = JevScreenExecutor(evaluate: client.evaluate, execute: { call in
            if let text = call.parameters["text"] { texts.append(text) }
            return .init(result: call.name == "observe_screen" ? try delegationScreen("filled") : "delivered", isError: false)
        }, check: {}, diagnostic: { _ in })
        let value = "周测试🙂"
        let result = try await executor.run(JevDelegation(goal: "搜索联系人", completion: "出现匹配联系人",
            inputText: value, inputPurpose: "联系人搜索框"))
        #expect(texts == [.string(value)])
        #expect(result.contains("need_input"))
        #expect(client.requests.last?.0["input_consumed"] == .bool(true))
        #expect(client.requests.last?.0["input_value"] == nil)
    }

    @Test @MainActor func missingInputReturnsWithoutGuessingOrTyping() async throws {
        let client = DelegationJev([("type", nil)])
        var calls: [String] = []
        let executor = JevScreenExecutor(evaluate: client.evaluate, execute: { call in
            calls.append(call.name); return .init(result: try delegationScreen("search"), isError: false)
        }, check: {}, diagnostic: { _ in })
        let result = try await executor.run(JevDelegation(goal: "查找联系人", completion: "显示联系人"))
        #expect(result.contains("need_input"))
        #expect(calls == ["observe_screen"])
    }

    @Test @MainActor func cancellationAfterSelectionSendsNoInput() async throws {
        let client = DelegationJev([("tap", "target")])
        var cancelled = false, calls: [String] = []
        client.beforeReply = { cancelled = true }
        let executor = JevScreenExecutor(evaluate: client.evaluate, execute: { call in
            calls.append(call.name); return .init(result: try delegationScreen("f"), isError: false)
        }, check: { if cancelled { throw AssistantError.cancelled } }, diagnostic: { _ in })
        await #expect(throws: AssistantError.cancelled) {
            try await executor.run(JevDelegation(goal: "点击", completion: "进入新页面"))
        }
        #expect(calls == ["observe_screen"])
    }

    @Test @MainActor func failedInputStopsWithoutRetryAndActionLimitHandsBackFreshObservation() async throws {
        for failed in [true, false] {
            let client = DelegationJev([("tap", "target")])
            var taps = 0
            let executor = JevScreenExecutor(maxActions: 1, evaluate: client.evaluate, execute: { call in
                if call.name == "tap_text" { taps += 1; return .init(result: failed ? "unknown delivery" : "delivered", isError: failed) }
                return .init(result: try delegationScreen(taps == 0 ? "before" : "after"), isError: false)
            }, check: {}, diagnostic: { _ in })
            if failed {
                await #expect(throws: AssistantError.unavailable("unknown delivery")) {
                    try await executor.run(JevDelegation(goal: "点击", completion: "新页面"))
                }
            } else {
                let result = try await executor.run(JevDelegation(goal: "点击", completion: "新页面"))
                #expect(result.contains("step_limit"))
                #expect(result.contains("after"))
            }
            #expect(taps == 1)
        }
    }

    @Test @MainActor func crossFramePaginationFailsBeforeInference() async throws {
        let client = DelegationJev([])
        let executor = JevScreenExecutor(evaluate: client.evaluate, execute: { _ in
            .init(result: try delegationScreen("other"), isError: false)
        }, check: {}, diagnostic: { _ in })
        await #expect(throws: AssistantError.invalid("OCR 分页跨越不同画面。")) {
            try await executor.run(JevDelegation(goal: "读取", completion: "得到内容"),
                                   initialObservation: delegationScreen("first", next: 1))
        }
        #expect(client.requests.isEmpty)
    }

    @Test @MainActor func unsentCorrectionReturnsDeliveredPrefixAndFreshScreenWithoutReplay() async throws {
        let client = DelegationJev([("type", nil), ("tap", "target")])
        var calls: [String] = [], observation = 0
        let executor = JevScreenExecutor(evaluate: client.evaluate, execute: { call in
            calls.append(call.name)
            if call.name == "tap_text" {
                throw WorkflowCorrectionRequired("画面已变化", requiresObservation: true)
            }
            if call.name == "observe_screen" {
                observation += 1
                return .init(result: try delegationScreen("frame-\(observation)"), isError: false)
            }
            return .init(result: "delivered", isError: false)
        }, check: {}, diagnostic: { _ in })
        let result = try await executor.run(JevDelegation(goal: "填写并提交搜索", completion: "出现结果",
            inputText: "测试🙂\n第二行", inputPurpose: "搜索字段"))
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        #expect(object["status"] as? String == "blocked")
        #expect(object["overall_success"] as? Bool == false)
        #expect(object["input_consumed"] as? Bool == true)
        let actions = try #require(object["actual_actions"] as? [[String: Any]])
        #expect(actions.count == 1)
        #expect(actions[0]["tool"] as? String == "type_text")
        let screen = try #require(object["screen"] as? [String: Any])
        #expect(screen["frame_id"] as? String == "frame-3")
        #expect(calls == ["observe_screen", "type_text", "observe_screen", "tap_text", "observe_screen"])
    }

    @Test @MainActor func missingSelectedTargetStopsWithoutSubstitution() async throws {
        let client = DelegationJev([("tap", nil)])
        var calls: [String] = []
        let executor = JevScreenExecutor(evaluate: client.evaluate, execute: { call in
            calls.append(call.name)
            return .init(result: try delegationScreen("f"), isError: false)
        }, check: {}, diagnostic: { _ in })
        await #expect(throws: AssistantError.invalid("Jev 响应 JSON 字段无法解析；没有发送设备操作。")) {
            try await executor.run(JevDelegation(goal: "点击", completion: "进入结果页"))
        }
        #expect(calls == ["observe_screen"])
    }
}

private final class DelegationModel: ModelProvider, @unchecked Sendable {
    static let name = "main-agent-fixture"
    let configuration = ProviderConfiguration(name: name, baseURL: URL(string: "https://fixture.invalid")!)
    private let lock = NSLock()
    private var calls = 0
    let reply: @Sendable (ModelRequest, Int) throws -> ModelResponse
    init(_ reply: @escaping @Sendable (ModelRequest, Int) throws -> ModelResponse) { self.reply = reply }
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        let index = lock.withLock { let n = calls; calls += 1; return n }
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

private final class DelegationDevice: @unchecked Sendable {
    let lock = NSLock()
    var actions: [String] = []
    var taps = 0
    func execute(_ name: String) throws -> String {
        try lock.withLock {
            actions.append(name)
            if name == "tap_text" { taps += 1 }
            if name == "observe_screen" { return try delegationScreen("frame-\(taps)", taps == 0 ? "微博首页 推荐 发现" : "1 测试热搜") }
            return "delivered"
        }
    }
}

private struct DelegationDeviceTool: AgentTool {
    let name: String
    let device: DelegationDevice
    var description: String { name }
    var parameters: ToolParameters {
        if name == "tap_text" {
            return .init(properties: ["frame_id": .init(type: "string", description: "frame"),
                "candidate_id": .init(type: "string", description: "candidate"),
                "purpose": .init(type: "string", description: "purpose")], required: ["frame_id", "candidate_id", "purpose"])
        }
        return .empty
    }
    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        .success(toolCallId: "", toolName: name, result: try device.execute(name))
    }
}

struct JevHarnessTests {
    @Test @MainActor func earlyDoneReturnsToMainAgentWithSkillsMemoryAndCorrelatedResults() async throws {
        let device = DelegationDevice()
        let client = DelegationJev([("subgoal_done", nil), ("tap", "target"), ("subgoal_done", nil)])
        let model = DelegationModel { request, index in
            let all = request.messages.map(\.content).joined(separator: "\n")
            #expect(all.contains("只回答第一条"))
            #expect(all.contains("weibo"))
            let calls: [ModelToolCall]
            switch index {
            case 0:
                #expect(!(request.tools ?? []).contains { $0.name == "delegate_screen" })
                calls = [.init(id: "base", name: "load_skill", arguments: "{\"name\":\"ios-operation\"}"),
                         .init(id: "weibo", name: "load_skill", arguments: "{\"name\":\"weibo\"}")]
            case 1:
                #expect((request.tools ?? []).contains { $0.name == "delegate_screen" })
                #expect(all.contains("热搜导航知识"))
                calls = [.init(id: "stage1", name: "delegate_screen", arguments: "{\"goal\":\"到达热搜榜\",\"completion\":\"显示排名\"}")]
            case 2:
                let receipt = try #require(request.messages.first { $0.toolCallId == "stage1" })
                #expect(receipt.content.contains("subgoal_done"))
                #expect(receipt.content.contains("微博首页"))
                calls = [.init(id: "stage2", name: "delegate_screen", arguments: "{\"goal\":\"继续进入榜单，当前首页未完成\",\"completion\":\"显示排名第一条\"}")]
            default:
                let receipt = try #require(request.messages.first { $0.toolCallId == "stage2" })
                #expect(receipt.content.contains("actual_actions"))
                #expect(receipt.content.contains("测试热搜"))
                #expect(receipt.content.contains("\"overall_success\":false"))
                return .init(text: "第一条热搜是测试热搜。", finishReason: .stop, request: request, providerName: Self.name)
            }
            return .init(text: "", finishReason: .toolCalls, toolCalls: calls, request: request, providerName: Self.name)
        }
        let skills = try [
            SkillPackage.make(documents: ["SKILL.md": "---\nname: ios-operation\ndescription: 操作基础\n---\n按屏幕操作。"]),
            SkillPackage.make(documents: ["SKILL.md": "---\nname: weibo\ndescription: 微博\n---\n热搜导航知识"])
        ]
        var answers: [String] = [], turns: [Int] = [], completed: [Int] = []
        let engine = HarnessAgentEngine(provider: model, model: "main-fixture", query: "第一条热搜是什么", images: [],
            history: [], maxTokens: 1000, maxTurns: 12,
            tools: ["observe_screen", "tap_text"].map { DelegationDeviceTool(name: $0, device: device) },
            skills: skills, workflows: [], pages: [], runPages: { _, _, _ in },
            receipt: { _, _ in }, diagnostic: { _ in }, cancelProvider: {}, jev: client)
        let answer = try await engine.run(context: "只回答第一条") { event in
            if case .programAnswer(let text) = event { answers.append(text) }
            if case .llmCallStarted(let turn) = event { turns.append(turn) }
            if case .llmCallCompleted(let turn, _) = event { completed.append(turn) }
        }
        #expect(answer == "第一条热搜是测试热搜。")
        #expect(answers == [answer])
        #expect(device.actions == ["observe_screen", "tap_text", "observe_screen"])
        #expect(turns == Array(1...7))
        #expect(completed == turns)
        #expect(client.cancelled)
    }

    @Test @MainActor func mainAndJevShareBudgetAndNeverReturnFalseSuccessOnExhaustion() async throws {
        let client = DelegationJev([("subgoal_done", nil)])
        let model = DelegationModel { request, index in
            let call = index == 0
                ? ModelToolCall(id: "skill", name: "load_skill", arguments: "{\"name\":\"ios-operation\"}")
                : ModelToolCall(id: "stage", name: "delegate_screen", arguments: "{\"goal\":\"读取\",\"completion\":\"看到内容\"}")
            return .init(text: "", finishReason: .toolCalls, toolCalls: [call], request: request, providerName: Self.name)
        }
        var answered = false
        let engine = HarnessAgentEngine(provider: model, model: "fixture", query: "读取", images: [], history: [],
            maxTokens: 1000, maxTurns: 3, tools: [DelegationDeviceTool(name: "observe_screen", device: DelegationDevice())],
            skills: [try SkillPackage.make(documents: ["SKILL.md": "---\nname: ios-operation\ndescription: fixture\n---\nObserve."])],
            workflows: [], pages: [], runPages: { _, _, _ in }, receipt: { _, _ in },
            diagnostic: { _ in }, cancelProvider: {}, jev: client)
        do {
            _ = try await engine.run(context: "") { if case .programAnswer = $0 { answered = true } }
            Issue.record("Expected budget exhaustion")
        } catch { #expect(error.localizedDescription.contains("预算")) }
        #expect(!answered)
        #expect(client.requests.count == 1)
    }
    private static let name = "main-agent-fixture"
}
