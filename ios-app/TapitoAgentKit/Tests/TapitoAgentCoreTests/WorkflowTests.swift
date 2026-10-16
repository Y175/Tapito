import Foundation
import Testing
import SwiftAgentKit
import TapitoAgentSwiftAgentKit
@testable import TapitoAgentCore

private let page = WorkflowPage(width: 1206, height: 2622, pixels: Data(repeating: 128, count: 3456))
private let button = Data(repeating: 128, count: 768)
private func trace(name: String = "notes.create", runID: UUID = UUID(), steps: [WorkflowStep]? = nil) -> WorkflowTrace {
    .init(runID: runID, name: name, appBundleID: "com.apple.mobilenotes", appVersion: "27.0", systemVersion: "iOS 27",
          steps: steps ?? [.init(action: .tap(x: 1100, y: 2300), page: page, targetPatch: button, purpose: "新建备忘录"),
                           .init(action: .insert(argument: "text_1"), page: page, purpose: "备忘录正文")], finalPage: page)
}
private func active(_ store: WorkflowLibrary, trace: WorkflowTrace = trace()) async throws -> LearnedWorkflow {
    try await store.enqueue(trace, expectedEpoch: store.epoch())
    try await store.processPending()
    let item = try #require(await store.workflows().last)
    try await store.activate(id: item.id, revision: item.revision)
    return try #require(await store.active().first)
}

private actor FixtureDevice: WorkflowDevice {
    var calls: [String] = []
    var texts: [String] = []
    var version = "27.0"
    var failureAt: Int?
    var changedPage = false
    var onStep: (@Sendable () async -> Void)?
    init(failureAt: Int? = nil, changedPage: Bool = false) { self.failureAt = failureAt; self.changedPage = changedPage }
    func setVersion(_ value: String) { version = value }
    func setOnStep(_ action: @escaping @Sendable () async -> Void) { onStep = action }
    func workflowVersion(app: String) async throws -> String { calls.append("version"); return version }
    func workflowLaunch(app: String, callID: String) async throws { calls.append(callID) }
    func workflowPerform(step: WorkflowStep, text: String?, callID: String) async throws {
        if changedPage { throw WorkflowMismatch.page }
        calls.append(callID)
        if let text { texts.append(text) }
        if let failureAt, calls.count == failureAt { throw AssistantError.unavailable("input outcome unknown") }
        await onStep?()
    }
    func workflowVerify(page: WorkflowPage, callID: String) async throws { calls.append(callID) }
}

struct WorkflowTests {
    @Test func durableQueueResumesWithoutExecutingAndRequiresReview() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = WorkflowLibrary(directory: directory), evidence = trace()
        try await first.enqueue(evidence, expectedEpoch: first.epoch())
        try await first.enqueue(evidence, expectedEpoch: first.epoch())
        let restored = WorkflowLibrary(directory: directory)
        #expect(try await restored.jobs().count == 1)
        try await restored.processPending()
        #expect(try await restored.workflows().count == 1)
        #expect(try await restored.active().isEmpty)
        #expect(try await restored.jobs().first?.state == "compiled")
        try await restored.processPending()
        #expect(try await restored.workflows().count == 1)
    }
    @Test func incompleteCoordinatesRejectWholeTrace() async throws {
        let store = WorkflowLibrary(directory: nil)
        let incomplete = trace(steps: [.init(action: .tap(x: 25, y: 30), page: nil, purpose: "没有新观察")])
        try await store.enqueue(incomplete, expectedEpoch: store.epoch())
        try await store.processPending()
        #expect(try await store.workflows().isEmpty)
        #expect(try await store.jobs().first?.state == "rejected")
        #expect(try await store.jobs().first?.message?.contains("输入前没有新的页面证据") == true)
    }
    @Test func parametersAreBoundOnceAndReceiptsAreOrdered() async throws {
        let item = try await active(WorkflowLibrary(directory: nil)), device = FixtureDevice()
        try await WorkflowExecutor.run(item, arguments: ["text_1": "今晚采购清单"], systemVersion: "iOS 27", callID: "run", device: device, permit: {})
        #expect(await device.calls == ["version", "run.launch", "run.step.0", "run.step.1", "run.verify"])
        #expect(await device.texts == ["今晚采购清单"])
        #expect(!String(decoding: try JSONEncoder().encode(item), as: UTF8.self).contains("今晚采购清单"))
    }
    @Test func malformedArgumentsAndInvalidLaterStepsFailBeforeLaunch() async throws {
        let item = try await active(WorkflowLibrary(directory: nil)), device = FixtureDevice()
        await #expect(throws: AssistantError.self) {
            try await WorkflowExecutor.run(item, arguments: [:], systemVersion: "iOS 27", callID: "run", device: device, permit: {})
        }
        #expect(await device.calls.isEmpty)
        let invalid = trace(steps: [.init(action: .tap(x: 2, y: 2), page: page, targetPatch: button, purpose: "有效"),
                                   .init(action: .tap(x: 2000, y: 3), page: page, targetPatch: button, purpose: "越界")])
        let bad = LearnedWorkflow(id: UUID(), revision: UUID(), trace: invalid, state: "active", successfulReplays: 0, createdAt: Date())
        await #expect(throws: AssistantError.self) {
            try await WorkflowExecutor.run(bad, arguments: [:], systemVersion: "iOS 27", callID: "bad", device: device, permit: {})
        }
        #expect(await device.calls.isEmpty)
    }
    @Test func versionMismatchNeverLaunchesAndPageMismatchStopsInputs() async throws {
        let item = try await active(WorkflowLibrary(directory: nil)), device = FixtureDevice()
        await device.setVersion("28")
        await #expect(throws: WorkflowMismatch.self) {
            try await WorkflowExecutor.run(item, arguments: ["text_1": "x"], systemVersion: "iOS 27", callID: "run", device: device, permit: {})
        }
        #expect(await device.calls == ["version"])
        let changed = FixtureDevice(changedPage: true)
        await #expect(throws: WorkflowMismatch.self) {
            try await WorkflowExecutor.run(item, arguments: ["text_1": "x"], systemVersion: "iOS 27", callID: "run", device: changed, permit: {})
        }
        #expect(await changed.calls == ["version", "run.launch"])
    }
    @Test func unknownDeliveryIsNeverRetriedNorFollowedByAnotherInput() async throws {
        let item = try await active(WorkflowLibrary(directory: nil)), device = FixtureDevice(failureAt: 3)
        await #expect(throws: AssistantError.self) {
            try await WorkflowExecutor.run(item, arguments: ["text_1": "x"], systemVersion: "iOS 27", callID: "run", device: device, permit: {})
        }
        #expect(await device.calls == ["version", "run.launch", "run.step.0"])
        #expect(await device.texts.isEmpty)
    }
    @Test func revocationBetweenStepsStopsTheChain() async throws {
        let store = WorkflowLibrary(directory: nil), item = try await active(store), device = FixtureDevice()
        await device.setOnStep { try! await store.disable(id: item.id) }
        await #expect(throws: AssistantError.conflict) {
            try await WorkflowExecutor.run(item, arguments: ["text_1": "x"], systemVersion: "iOS 27", callID: "run", device: device,
                permit: { try await store.requireActive(id: item.id, revision: item.revision) })
        }
        #expect(await device.calls == ["version", "run.launch", "run.step.0"])
    }
    @Test func cancellationAfterAReceiptDoesNotReplayOrContinue() async throws {
        let item = try await active(WorkflowLibrary(directory: nil)), device = FixtureDevice()
        await device.setOnStep { withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task {
            try await WorkflowExecutor.run(item, arguments: ["text_1": "x"], systemVersion: "iOS 27", callID: "run", device: device, permit: {})
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await device.calls == ["version", "run.launch", "run.step.0"])
    }
    @Test func driftQuarantinesAndReviewSupersedesOnlySameNamedWorkflow() async throws {
        let store = WorkflowLibrary(directory: nil), old = try await active(store)
        try await store.recordReplay(id: old.id, revision: old.revision, failure: "changed", stale: true)
        try await store.disable(id: old.id)
        await #expect(throws: AssistantError.self) { try await store.activate(id: old.id, revision: old.revision) }
        #expect(try await store.active().isEmpty)
        let new = try await active(store)
        #expect(new.id != old.id)
        #expect(try await store.workflows().count == 2)
        let epoch = try await store.epoch()
        try await store.clear()
        await #expect(throws: AssistantError.conflict) { try await store.enqueue(trace(), expectedEpoch: epoch) }
    }
    @Test func corruptedArchiveAndVisualDifferencesFailVisibly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("workflows-v1.json"))
        await #expect(throws: AssistantError.self) { _ = try await WorkflowLibrary(directory: directory).active() }
        #expect(try page.matches(page))
        #expect(try !page.matches(.init(width: 2622, height: 1206, pixels: page.pixels)))
        #expect(try !page.matches(.init(width: 1206, height: 2622, pixels: Data(repeating: 135, count: 3456))))
        #expect(throws: AssistantError.self) { try page.matches(.init(width: 1206, height: 2622, pixels: Data())) }
    }
}

struct WorkflowToolTests {
    @Test func unavailableHostCannotInvokeWorkflowOrChangeTrainingName() async throws {
        let tool = WorkflowTool(name: "name_workflow", snapshot: [], canAccess: { false },
            run: { _, _, _ in Issue.record("Device path must not be reached") }, label: { _ in Issue.record("Label path must not be reached") })
        await #expect(throws: CancellationError.self) {
            try await tool.execute(context: .init(callId: "blocked", toolName: tool.name, parameters: ["name": "notes.create"], state: AgentState()))
        }
    }
    @Test func catalogExcludesPixelEvidenceAndUnknownRevisionCannotRun() async throws {
        let flow = try await active(WorkflowLibrary(directory: nil))
        let list = WorkflowTool(name: "list_workflows", snapshot: [flow], canAccess: { true }, run: { _, _, _ in }, label: { _ in })
        let result = try await list.execute(context: .init(callId: "list", toolName: list.name,
            parameters: ["app_bundle_id": flow.trace.appBundleID], state: AgentState()))
        #expect(!result.isError && result.result.contains("text_1"))
        #expect(!result.result.contains("pixels") && !result.result.contains("targetPatch"))
        let run = WorkflowTool(name: "run_workflow", snapshot: [flow], canAccess: { true },
            run: { _, _, _ in Issue.record("Wrong revision must not dispatch") }, label: { _ in })
        let rejected = try await run.execute(context: .init(callId: "run", toolName: run.name,
            parameters: ["id": flow.id.uuidString, "revision": UUID().uuidString, "texts": ["x"]], state: AgentState()))
        #expect(rejected.isError)
    }
    @Test func disablingLearningCancelsPersistedPendingAnalysis() async throws {
        let library = WorkflowLibrary(directory: nil)
        try await library.enqueue(trace(), expectedEpoch: library.epoch())
        try await library.cancelPendingLearning()
        try await library.processPending()
        #expect(try await library.workflows().isEmpty)
        #expect(try await library.jobs().first?.state == "rejected")
    }
}
