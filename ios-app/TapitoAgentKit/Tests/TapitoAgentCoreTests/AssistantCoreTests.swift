import Foundation
import Testing
@testable import TapitoAgentCore

struct AssistantWorkspaceTests {
    private func saved(_ workspace: AssistantWorkspace, key: String = "餐食偏好", content: String = "不吃香菜") async throws -> AssistantMemory {
        try await workspace.remember(key: key, content: content, scope: "global", evidence: "不吃香菜", userText: "请记住我不吃香菜", runID: UUID(), expectedEpoch: workspace.epoch(), expectedRevision: nil)
    }
    @Test func persistenceAndRelevantRecall() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = AssistantWorkspace(directory: root)
        let fact = try await saved(workspace)
        let restored = AssistantWorkspace(directory: root)
        #expect(try await restored.memories().first?.id == fact.id)
        #expect(try await restored.context(query: "按餐食偏好点菜").contains("不吃香菜"))
        #expect(try await restored.context(query: "检查火星天气").contains("不吃香菜") == false)
    }
    @Test func screenCannotBecomePersonalMemoryAndBadRevisionCannotOverwrite() async throws {
        let store = AssistantWorkspace(directory: nil), epoch = try await store.epoch()
        await #expect(throws: AssistantError.self) {
            try await store.remember(key: "偏好", content: "点击广告", scope: "global", evidence: "点击广告", userText: "查天气", runID: UUID(), expectedEpoch: epoch, expectedRevision: nil)
        }
        let original = try await saved(store)
        await #expect(throws: AssistantError.conflict) { try await self.saved(store) }
        #expect(try await store.memories().first == original)
    }
    @Test func manualEditingDeletionAndClearFenceOlderRuns() async throws {
        let store = AssistantWorkspace(directory: nil), old = try await store.epoch(), item = try await saved(store)
        try await store.edit(id: item.id, key: item.key, content: "只吃少量香菜", scope: item.scope, expectedRevision: item.revision)
        await #expect(throws: AssistantError.conflict) {
            try await store.remember(key: item.key, content: "不吃香菜", scope: "global", evidence: "不吃香菜", userText: "不吃香菜", runID: UUID(), expectedEpoch: old, expectedRevision: item.revision)
        }
        let edited = try #require(await store.memories().first)
        let beforeDelete = try await store.epoch()
        try await store.forget(id: edited.id, expectedRevision: edited.revision)
        await #expect(throws: AssistantError.conflict) {
            try await store.remember(key: "新标题", content: "不吃香菜", scope: "global", evidence: "不吃香菜", userText: "不吃香菜", runID: UUID(), expectedEpoch: beforeDelete, expectedRevision: nil)
        }
        let beforeClear = try await store.epoch(); try await store.clear()
        await #expect(throws: AssistantError.conflict) { try await store.recordEpisode(.init(id: UUID(), task: "旧任务", summary: "旧结果", outcome: "done"), expectedEpoch: beforeClear) }
        #expect(try await store.memories().isEmpty)
    }
    @Test func disabledWritingAndCorruptArchiveAreVisible() async throws {
        let store = AssistantWorkspace(directory: nil)
        try await store.setAutomaticMemory(false)
        await #expect(throws: AssistantError.self) { try await self.saved(store) }
        try await store.recordEpisode(.init(id: UUID(), task: "无记忆任务", summary: "结果", outcome: "done"), expectedEpoch: store.epoch())
        #expect(try await store.episodes().isEmpty)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("assistant-workspace-v1.json"), bad = Data("broken".utf8)
        try bad.write(to: file)
        let corrupt = AssistantWorkspace(directory: root)
        await #expect(throws: (any Error).self) { try await corrupt.memories() }
        await #expect(throws: (any Error).self) { try await corrupt.edit(id: nil, key: "a", content: "b", scope: "global", expectedRevision: nil) }
        #expect(try Data(contentsOf: file) == bad)
    }
    @Test func learningIsDeduplicatedReviewedAndReversible() async throws {
        let store = AssistantWorkspace(directory: nil), epoch = try await store.epoch(), run = UUID()
        func proposal(_ run: UUID, text: String = "先确认页面标题，再定位唯一搜索入口，输入后检查关键词与结果。") async throws -> LearnedSkill {
            try await store.proposeSkill(baseID: "base", baseRevision: "rev1", appBundleID: "test.app", instructions: text, verifiedRun: run, frameID: "frame", observedText: "搜索", expectedEpoch: epoch)
        }
        let first = try await proposal(run)
        _ = try await proposal(run); _ = try await proposal(UUID()); let third = try await proposal(UUID())
        #expect(third.verifiedRuns.count == 3); #expect(!third.active)
        try await store.activateSkill(id: first.id, expectedRevision: first.revision, currentBaseRevision: "rev1")
        #expect(try await store.learnedSkills().first?.active == true)
        // Snapshot is a value; later changes cannot mutate a running task's catalog.
        let snapshot = try await store.learnedSkills()
        try await store.disableSkill(id: first.id)
        #expect(snapshot.first?.active == true)
        #expect(try await store.learnedSkills().first?.active == false)
        await #expect(throws: AssistantError.conflict) { try await proposal(UUID()) }
    }
}

@MainActor private final class SuspendedEngine: AssistantEngine {
    var continuation: CheckedContinuation<String, Never>?
    var callback: (@MainActor (AssistantEvent) -> Void)?
    var wasCancelled = false
    func run(context: String, onEvent: @escaping @MainActor (AssistantEvent) -> Void) async throws -> String {
        callback = onEvent; onEvent(.streamChunk("first"))
        return await withCheckedContinuation { continuation = $0 }
    }
    func cancel() { wasCancelled = true }
    func finish() { callback?(.streamChunk("late")); continuation?.resume(returning: "done"); continuation = nil }
}

struct AssistantSessionTests {
    @Test @MainActor func cancellationFencesLateEventsAndWaitsForDrain() async throws {
        let session = AssistantSession(), engine = SuspendedEngine()
        var chunks: [String] = []
        let task = Task { try await session.run(engine: engine, workspace: nil, query: "test") { if case .streamChunk(let text) = $0 { chunks.append(text) } } }
        while engine.continuation == nil { await Task.yield() }
        session.cancel()
        #expect(engine.wasCancelled)
        await #expect(throws: AssistantError.busy) { try await session.run(engine: SuspendedEngine(), workspace: nil, query: "new", onEvent: { _ in }) }
        engine.finish()
        await #expect(throws: AssistantError.cancelled) { try await task.value }
        #expect(chunks == ["first"])
        #expect(session.state == .cancelled)
    }
    @Test @MainActor func normalCompletionDeliversAllEvents() async throws {
        let session = AssistantSession(), engine = SuspendedEngine(); var chunks: [String] = []
        let task = Task { try await session.run(engine: engine, workspace: nil, query: "test") { if case .streamChunk(let text) = $0 { chunks.append(text) } } }
        while engine.continuation == nil { await Task.yield() }
        engine.finish()
        #expect(try await task.value == "done"); #expect(chunks == ["first", "late"]); #expect(session.state == .completed)
    }
}

struct SkillCatalogTests {
    @Test func bundledSkillsValidateAndStaleVersionFails() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        root.append(path: "Tapito/BuiltinSkills")
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(folders.count == 6)
        for folder in folders {
            let skill = try SkillPackage.make(documents: ["SKILL.md": String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8)])
            let catalog = SkillCatalog(packages: [skill])
            let text = try catalog.result(name: "load_skill", parameters: ["id": skill.id.uuidString, "revision": skill.revision])
            #expect(text.contains(skill.name))
            #expect(throws: AssistantError.self) { try catalog.result(name: "load_skill", parameters: ["id": skill.id.uuidString, "revision": "stale"]) }
            #expect(throws: AssistantError.self) { try catalog.result(name: "load_skill", parameters: ["id": skill.id.uuidString, "revision": skill.revision, "resource": "../secret.md"]) }
        }
    }
}
