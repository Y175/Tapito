import Foundation
import Testing
import SwiftAgentKit
import ProviderCore
import TapitoAgentCore
import TapitoAgentSwiftAgentKit

private final class Trace: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func read() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
}
private struct FixtureProvider: ModelProvider {
    static let name = "assistant-fixture"
    let configuration = ProviderConfiguration(name: name, baseURL: URL(string: "https://fixture.invalid")!)
    let trace: Trace
    func complete(_ request: ModelRequest) async throws -> ModelResponse { throw AssistantError.invalid("Only streaming is allowed in this fixture") }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { stream in
            if request.messages.contains(where: { $0.role == .tool }) {
                trace.add("request2")
                stream.yield(.text("verified final")); stream.yield(.finish(reason: .stop, usage: .init(totalTokens: 10)))
            } else {
                trace.add("request1")
                stream.yield(.reasoning("readable summary"))
                stream.yield(.toolCall(.init(id: "one", name: "fixture", arguments: "{}")))
                stream.yield(.finish(reason: .toolCalls, usage: nil))
            }
            stream.finish()
        }
    }
}
private struct FixtureTool: AgentTool {
    let trace: Trace
    let name = "fixture"
    let description = "A synthetic tool that does not control devices or networks."
    var parameters: ToolParameters { .empty }
    func execute(parameters: [String: Any]) async throws -> AgentToolResult { throw AssistantError.invalid("Needs context") }
    func execute(context: ToolContext) async throws -> AgentToolResult {
        trace.add("tool"); context.actions.skipSummarization = true
        return .success(toolCallId: context.callId, toolName: name, result: "synthetic receipt")
    }
}
struct EngineIntegrationTests {
    @Test @MainActor func realEnginePreservesReceiptsAndEventOrder() async throws {
        let trace = Trace(), provider = FixtureProvider(trace: trace)
        let config = AgentConfig(provider: provider, model: "fixture", maxTokens: 1_000, systemPrompt: "fixture",
            maxTurns: 3, enablePlanning: false, enableRepairRetry: false, enablePlanContinuation: false,
            tools: [FixtureTool(trace: trace)], autonomousMode: false, enableSubAgents: false,
            maxVerificationRetries: 0, loopDetection: nil, parallelToolCalls: false, progressNudgeFractions: [])
        let engine = SwiftAgentEngine(config: config, query: "synthetic", images: [], history: [], receipt: { _, result in
            #expect(!result.isError); trace.add("receipt")
        }, diagnostic: { trace.add("diagnostic:" + $0) })
        var chunks: [String] = [], tools: [String] = []
        let answer = try await AssistantSession().run(engine: engine, workspace: nil, query: "synthetic") { event in
            switch event {
            case .streamChunk(let text): chunks.append(text)
            case .toolExecutionStarted(let call): tools.append("start:" + call.id)
            case .toolExecutionFinished(let call, _): tools.append("end:" + call.id)
            default: break
            }
        }
        #expect(answer == "verified final"); #expect(chunks.joined() == answer)
        #expect(tools == ["start:one", "end:one"])
        let values = trace.read()
        #expect(try #require(values.firstIndex(of: "receipt")) < #require(values.firstIndex(of: "request2")))
    }
    @Test func adapterRejectsInvalidJSONParameters() throws {
        #expect(throws: (any Error).self) { try SwiftAgentEngine.call(.init(name: "fixture", parameters: ["bad": AnyCodable(Double.nan)])) }
    }
    @Test func learningCannotBypassHostObservationOrBaseRevision() async throws {
        let workspace = AssistantWorkspace(directory: nil), epoch = try await workspace.epoch()
        let args = ["skill_id": "base", "revision": "rev", "app_bundle_id": "test.app", "instructions": "核对当前页面的标题，点击唯一搜索入口，再检查搜索结果标题。", "frame_id": "old-frame", "expected_text": "搜索"]
        let context = ToolContext(callId: "candidate", toolName: "propose_skill_update", parameters: args, state: AgentState())
        let tool = WorkspaceTool(name: "propose_skill_update", workspace: workspace, epoch: epoch, runID: UUID(), userText: "查热搜",
            skills: [.init(id: "base", revision: "rev")], canAccess: { true }, verifyObservation: { _, _, _ in throw AssistantError.invalid("stale frame") })
        #expect(try await tool.execute(context: context).isError)
        #expect(try await workspace.learnedSkills().isEmpty)
        let noPermission = WorkspaceTool(name: "propose_skill_update", workspace: workspace, epoch: epoch, runID: UUID(), userText: "查热搜",
            skills: [.init(id: "base", revision: "rev")], canAccess: { false }, verifyObservation: { _, _, _ in Issue.record("Permission fence failed") })
        await #expect(throws: CancellationError.self) { try await noPermission.execute(context: context) }
    }
    @Test func activatedSkillIsPinnedAndReadThroughPagedCatalog() async throws {
        let workspace = AssistantWorkspace(directory: nil)
        let package = try SkillPackage.make(documents: ["SKILL.md": "---\nname: fixture\ndescription: fixture skill\n---\nbase document"])
        let candidate = try await workspace.proposeSkill(baseID: package.id.uuidString, baseRevision: package.revision, appBundleID: "test.app",
            instructions: "LEARNED_STEP: 先确认当前页面的标题，再点击唯一文字目标并重新观察。", verifiedRun: UUID(), frameID: "frame", observedText: "搜索", expectedEpoch: workspace.epoch())
        let before = SkillCatalog(packages: [package], additions: try await workspace.learnedSkills())
        try await workspace.activateSkill(id: candidate.id, expectedRevision: candidate.revision, currentBaseRevision: package.revision)
        let after = SkillCatalog(packages: [package], additions: try await workspace.learnedSkills())
        let args: [String: Any] = ["id": package.id.uuidString, "revision": package.revision]
        #expect(try !before.result(name: "load_skill", parameters: args).contains("LEARNED_STEP"))
        #expect(try after.result(name: "load_skill", parameters: args).contains("LEARNED_STEP"))
        let revised = try SkillPackage.make(documents: ["SKILL.md": package.documents["SKILL.md"]! + "\nchanged"])
        let newerBase = SkillPackage(id: package.id, name: revised.name, summary: revised.summary, version: revised.version, revision: revised.revision, documents: revised.documents, enabled: true)
        let stale = SkillCatalog(packages: [newerBase], additions: try await workspace.learnedSkills())
        #expect(try !stale.result(name: "load_skill", parameters: ["id": package.id.uuidString, "revision": revised.revision]).contains("LEARNED_STEP"))
    }
}

struct MemoryToolPagingTests {
    @Test func memorySearchReturnsCompletePages() async throws {
        let workspace = AssistantWorkspace(directory: nil)
        for index in 0..<7 {
            try await workspace.edit(id: nil, key: "偏好\(index)", content: String(repeating: "明确偏好", count: 180), scope: "global", expectedRevision: nil)
        }
        let tool = WorkspaceTool(name: "search_memory", workspace: workspace, epoch: try await workspace.epoch(), runID: UUID(), userText: "查询",
            skills: [], canAccess: { true }, verifyObservation: { _, _, _ in Issue.record("Not a learning call") })
        let result = try await tool.execute(context: .init(callId: "page1", toolName: "search_memory", parameters: ["query": "偏好"], state: AgentState()))
        #expect(!result.isError)
        let json = try #require(JSONSerialization.jsonObject(with: Data(result.result.utf8)) as? [String: Any])
        #expect((json["memories"] as? [[String: Any]])?.count == 3)
        #expect(json["total_matches"] as? Int == 7)
        #expect(json["next_offset"] as? Int == 3)
        #expect(result.result.count < 8_000)
        let bad = try await tool.execute(context: .init(callId: "bad", toolName: "search_memory", parameters: ["query": "偏好", "offset": -1], state: AgentState()))
        #expect(bad.isError)
    }
}
