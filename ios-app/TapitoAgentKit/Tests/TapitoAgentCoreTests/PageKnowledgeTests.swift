import Foundation
import Testing
@testable import TapitoAgentCore

func uiPage(_ id: String = UUID().uuidString, label: String = "首页", patches: Bool = false) -> InterfaceSkeleton {
    .init(frameID: id, width: 1206, height: 2622, anchors: [
        .init(text: label, bounds: .init(x: 50, y: 2300, width: 100, height: 60), patch: patches ? Data(repeating: 20, count: 768) : nil),
        .init(text: "搜索", bounds: .init(x: 150, y: 200, width: 300, height: 60), patch: patches ? Data(repeating: 25, count: 768) : nil)
    ])
}
func transition(_ runID: UUID = UUID(), action: PageControlAction = .tap, patches: Bool = false) -> PageTransitionEvidence {
    let before = uiPage(patches: patches)
    return .init(runID: runID, appBundleID: "test.app", appVersion: "1", systemVersion: "iOS 27",
                 before: before, control: before.anchors[1], action: action, after: uiPage(label: "取消", patches: patches))
}
func capability(action: PageControlAction = .tap) -> PageCapability {
    .init(evidence: transition(action: action), pageName: "首页", function: "进入搜索", observedResult: "显示取消入口", state: "active")
}
private actor PageDevice: PageWorkflowDevice {
    var calls: [String] = []
    var texts: [String?] = []
    let failDispatch: Bool
    let mismatchAt: Int?
    let reuseFrame: Bool
    var onInput: (@Sendable () async throws -> Void)?
    init(failDispatch: Bool = false, mismatchAt: Int? = nil, reuseFrame: Bool = false) {
        self.failDispatch = failDispatch; self.mismatchAt = mismatchAt; self.reuseFrame = reuseFrame
    }
    func hook(_ closure: @escaping @Sendable () async throws -> Void) { onInput = closure }
    func pageVersion(app: String) async throws -> String { calls.append("version"); return "1" }
    func pageObserve(matching reference: InterfaceSkeleton, callID: String) async throws -> InterfaceSkeleton {
        calls.append(callID)
        if calls.count == mismatchAt { throw WorkflowMismatch.page }
        return .init(frameID: reuseFrame ? "same-frame" : UUID().uuidString, width: reference.width,
                     height: reference.height, anchors: reference.anchors)
    }
    func pagePerform(capability: PageCapability, text: String?, observation: InterfaceSkeleton, callID: String) async throws {
        calls.append(callID); texts.append(text)
        if failDispatch { throw AssistantError.unavailable("outcome unknown") }
        try await onInput?()
    }
}
struct PageKnowledgeTests {
    @Test func skeletonRejectsContentInvalidCoordinatesAndSamples() throws {
        #expect(throws: AssistantError.self) { try uiPage(label: "张先生今晚八点见").validate() }
        let bad = InterfaceSkeleton(frameID: "x", width: 1206, height: 2622, anchors: [
            .init(text: "首页", bounds: .init(x: 9999, y: 3, width: 40, height: 40)), uiPage().anchors[1]])
        #expect(throws: AssistantError.self) { try bad.validate() }
        let patch = InterfaceAnchor(text: "首页", bounds: uiPage().anchors[0].bounds, patch: Data([0]))
        #expect(throws: AssistantError.self) { try InterfaceSkeleton(frameID: "x", width: 1206, height: 2622, anchors: [patch, uiPage().anchors[1]]).validate() }
        #expect(try uiPage().matches(uiPage()))
        #expect(try !uiPage().matches(uiPage(label: "设置")))
    }
    @Test func visualControlsRequireDigestButDoNotPersistRawIconPixels() throws {
        let before = uiPage(), after = uiPage(label: "取消")
        let box = InterfaceBounds(x: 1030, y: 200, width: 48, height: 48)
        let control = InterfaceAnchor(text: "图标", bounds: box, visualDigest: String(repeating: "a", count: 64))
        let evidence = PageTransitionEvidence(runID: UUID(), appBundleID: "test.app", appVersion: "1", systemVersion: "iOS 27",
            before: before, control: control, action: .tap, after: after)
        try evidence.validate()
        #expect(control.patch == nil)
        let bad = PageTransitionEvidence(runID: UUID(), appBundleID: "test.app", appVersion: "1", systemVersion: "iOS 27",
            before: before, control: .init(text: "图标", bounds: box), action: .tap, after: after)
        #expect(throws: AssistantError.self) { try bad.validate() }
    }
    @Test func sequenceBindsParametersAndRunsWithoutModels() async throws {
        let item = capability(action: .focusAndType), device = PageDevice()
        try await PageWorkflowExecutor.run(calls: [.init(id: item.id, revision: item.revision, text: "本次输入")], snapshot: [item],
            app: "test.app", systemVersion: "iOS 27", runID: "r", device: device, permit: { _ in })
        #expect(await device.calls == ["version", "r.0.before", "r.0", "r.0.after"])
        #expect(await device.texts == ["本次输入"])
        #expect(!String(decoding: try JSONEncoder().encode(item), as: UTF8.self).contains("本次输入"))
    }
    @Test func invalidLaterStepPreventsEveryInput() async throws {
        let item = capability(), device = PageDevice()
        await #expect(throws: AssistantError.self) {
            try await PageWorkflowExecutor.run(calls: [.init(id: item.id, revision: item.revision), .init(id: UUID(), revision: UUID())],
                snapshot: [item], app: "test.app", systemVersion: "iOS 27", runID: "r", device: device, permit: { _ in })
        }
        #expect(await device.calls.isEmpty)
    }
    @Test func mismatchIncludesProgressAndUnknownDispatchNeverRetries() async throws {
        let item = capability(), mismatch = PageDevice(mismatchAt: 4)
        do {
            try await PageWorkflowExecutor.run(calls: [.init(id: item.id, revision: item.revision)], snapshot: [item],
                app: "test.app", systemVersion: "iOS 27", runID: "r", device: mismatch, permit: { _ in })
            Issue.record("Expected deviation")
        } catch let error as PageWorkflowDeviation {
            #expect(error.completed == 0 && error.inputDelivered && error.capabilityID == item.id)
        }
        let unknown = PageDevice(failDispatch: true)
        await #expect(throws: AssistantError.self) {
            try await PageWorkflowExecutor.run(calls: [.init(id: item.id, revision: item.revision), .init(id: item.id, revision: item.revision)],
                snapshot: [item], app: "test.app", systemVersion: "iOS 27", runID: "r", device: unknown, permit: { _ in })
        }
        #expect(await unknown.calls == ["version", "r.0.before", "r.0"])
    }
    @Test func stalePostconditionCannotVerifySuccess() async throws {
        let item = capability(), device = PageDevice(reuseFrame: true)
        await #expect(throws: AssistantError.self) {
            try await PageWorkflowExecutor.run(calls: [.init(id: item.id, revision: item.revision)], snapshot: [item],
                app: "test.app", systemVersion: "iOS 27", runID: "r", device: device, permit: { _ in })
        }
        #expect(await device.calls.count == 4)
    }
    @Test func cancellationAfterInputStopsBeforeNextObservation() async throws {
        let item = capability(), device = PageDevice()
        await device.hook { withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task {
            try await PageWorkflowExecutor.run(calls: [.init(id: item.id, revision: item.revision)], snapshot: [item],
                app: "test.app", systemVersion: "iOS 27", runID: "r", device: device, permit: { _ in })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await device.calls == ["version", "r.0.before", "r.0"])
    }
}
struct KnowledgeQueueTests {
    @Test func durableQueueDeduplicatesAndRequiresReview() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = KnowledgeLibrary(directory: dir), workspace = AssistantWorkspace(directory: nil), run = UUID()
        let evidence = transition(run)
        for _ in 0..<2 {
            try await library.enqueue(runID: run, workspaceEpoch: workspace.epoch(), expectedEpoch: library.epoch(), userText: "打开搜索",
                providerID: UUID(), providerScope: "fixture-scope", model: "fixture", transitions: [evidence])
        }
        let restored = KnowledgeLibrary(directory: dir)
        #expect(try await restored.jobs().count == 1)
        try await restored.processPending(workspace: workspace) { job, _ in
            #expect(job.id == run)
            return ([], [.init(evidenceID: evidence.id, pageName: "首页", function: "进入搜索", observedResult: "出现取消")])
        }
        #expect(try await restored.active().isEmpty)
        let item = try #require(await restored.capabilities().first)
        try await restored.activate(id: item.id, revision: item.revision)
        #expect(try await restored.active().count == 1)
        try await restored.markStale(id: item.id, revision: item.revision)
        #expect(try await restored.active().isEmpty)
        await #expect(throws: AssistantError.conflict) { try await restored.activate(id: item.id, revision: item.revision) }
    }
    @Test func invalidAnnotationDoesNotPartiallyWriteMemories() async throws {
        let library = KnowledgeLibrary(directory: nil), workspace = AssistantWorkspace(directory: nil), evidence = transition()
        try await library.enqueue(runID: evidence.runID, workspaceEpoch: workspace.epoch(), expectedEpoch: library.epoch(), userText: "我喜欢简洁回复",
            providerID: UUID(), providerScope: "fixture-scope", model: "fixture", transitions: [evidence])
        try await library.processPending(workspace: workspace) { _, _ in
            ([.init(key: "style", content: "简洁回复", scope: "global", evidence: "我喜欢简洁回复", revision: nil)],
             [.init(evidenceID: UUID(), pageName: "首页", function: "进入搜索", observedResult: "出现取消")])
        }
        #expect(try await library.jobs().first?.state == "failed")
        #expect(try await workspace.memories().isEmpty)
        #expect(try await library.capabilities().isEmpty)
    }
    @Test func clearingDuringAnalysisCannotRestoreDeletedKnowledge() async throws {
        let library = KnowledgeLibrary(directory: nil), workspace = AssistantWorkspace(directory: nil)
        try await library.enqueue(runID: UUID(), workspaceEpoch: workspace.epoch(), expectedEpoch: library.epoch(), userText: "我喜欢简洁回复",
            providerID: UUID(), providerScope: "fixture-scope", model: "fixture", transitions: [])
        try await library.processPending(workspace: workspace) { _, _ in
            try await library.clear()
            return ([.init(key: "style", content: "简洁回复", scope: "global", evidence: "我喜欢简洁回复", revision: nil)], [])
        }
        #expect(try await workspace.memories().isEmpty)
        #expect(try await library.jobs().isEmpty)
    }
    @Test func disablingMemoryWhileAwaitingModelRejectsResult() async throws {
        let library = KnowledgeLibrary(directory: nil), workspace = AssistantWorkspace(directory: nil)
        try await library.enqueue(runID: UUID(), workspaceEpoch: workspace.epoch(), expectedEpoch: library.epoch(), userText: "测试",
            providerID: UUID(), providerScope: "fixture-scope", model: "fixture", transitions: [])
        try await library.processPending(workspace: workspace) { _, _ in
            try await workspace.setAutomaticMemory(false)
            return ([], [])
        }
        #expect(try await library.jobs().first?.state == "rejected")
    }
    @Test func deletingWhileAnalysisRunsRejectsInsteadOfRestartingTheJob() async throws {
        let library = KnowledgeLibrary(directory: nil), workspace = AssistantWorkspace(directory: nil)
        try await library.enqueue(runID: UUID(), workspaceEpoch: workspace.epoch(), expectedEpoch: library.epoch(), userText: "测试",
            providerID: UUID(), providerScope: "fixture", model: "fixture", transitions: [])
        try await library.processPending(workspace: workspace) { _, _ in
            // Individual deletion advances the review fence even when the old item has already disappeared.
            try await library.delete(id: UUID())
            return ([], [])
        }
        #expect(try await library.jobs().first?.state == "rejected")
    }
    @Test func quarantineDoesNotInvalidateNewEvidenceFromCorrectingRun() async throws {
        let library = KnowledgeLibrary(directory: nil), workspace = AssistantWorkspace(directory: nil), evidence = transition()
        try await library.enqueue(runID: evidence.runID, workspaceEpoch: workspace.epoch(), expectedEpoch: library.epoch(), userText: "测试",
            providerID: UUID(), providerScope: "fixture", model: "fixture", transitions: [evidence])
        try await library.processPending(workspace: workspace) { _, _ in
            ([], [.init(evidenceID: evidence.id, pageName: "首页", function: "搜索", observedResult: "取消")])
        }
        let item = try #require(await library.capabilities().first)
        try await library.activate(id: item.id, revision: item.revision)
        let epoch = try await library.epoch()
        try await library.markStale(id: item.id, revision: item.revision)
        try await library.enqueue(runID: UUID(), workspaceEpoch: workspace.epoch(), expectedEpoch: epoch, userText: "修正后完成",
            providerID: UUID(), providerScope: "fixture", model: "fixture", transitions: [])
        #expect(try await library.jobs().last?.state == "pending")
    }
    @Test func repeatedIndependentEvidenceDoesNotFloodOrEnableTheLibrary() async throws {
        let library = KnowledgeLibrary(directory: nil), workspace = AssistantWorkspace(directory: nil)
        for _ in 0..<2 {
            let evidence = transition()
            try await library.enqueue(runID: evidence.runID, workspaceEpoch: workspace.epoch(), expectedEpoch: library.epoch(), userText: "搜索",
                providerID: UUID(), providerScope: "fixture", model: "fixture", transitions: [evidence])
            try await library.processPending(workspace: workspace) { _, _ in
                ([], [.init(evidenceID: evidence.id, pageName: "首页", function: "搜索", observedResult: "取消")])
            }
        }
        #expect(try await library.jobs().count == 2)
        #expect(try await library.capabilities().count == 1)
        #expect(try await library.active().isEmpty)
    }
    @Test func memoryExtractionIsIdempotentAndCannotOverwriteNewManualRevision() async throws {
        let workspace = AssistantWorkspace(directory: nil), run = UUID(), epoch = try await workspace.epoch()
        let proposal = MemoryProposal(key: "回复风格", content: "简洁", scope: "global", evidence: "我喜欢简洁回复", revision: nil)
        for _ in 0..<2 { try await workspace.applyLearning([proposal], userText: "我喜欢简洁回复", runID: run, expectedEpoch: epoch) }
        #expect(try await workspace.memories().count == 1)
        let original = try #require(await workspace.memories().first)
        try await workspace.edit(id: original.id, key: original.key, content: "详细", scope: original.scope, expectedRevision: original.revision)
        let stale = MemoryProposal(key: original.key, content: "简洁", scope: original.scope, evidence: "我喜欢简洁回复", revision: original.revision)
        await #expect(throws: AssistantError.conflict) {
            try await workspace.applyLearning([stale], userText: "我喜欢简洁回复", runID: UUID(), expectedEpoch: epoch)
        }
        #expect(try await workspace.memories().first?.content == "详细")
    }
    @Test func crossRunEvidenceCannotEnterQueue() async throws {
        let library = KnowledgeLibrary(directory: nil), workspace = AssistantWorkspace(directory: nil)
        await #expect(throws: AssistantError.self) {
            try await library.enqueue(runID: UUID(), workspaceEpoch: workspace.epoch(), expectedEpoch: library.epoch(), userText: "测试",
                providerID: UUID(), providerScope: "fixture", model: "fixture", transitions: [transition()])
        }
        #expect(try await library.jobs().isEmpty)
    }
    @Test func corruptArchiveIsPreservedAndFailureIsVisible() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("agent-knowledge-v1.json")
        try Data("broken".utf8).write(to: file)
        await #expect(throws: AssistantError.self) { _ = try await KnowledgeLibrary(directory: dir).active() }
        #expect(try String(contentsOf: file, encoding: .utf8) == "broken")
    }
}
