import XCTest
import UIKit
import TapitoAgentCore
@testable import Tapito

/// Compiles against the real iOS adapter; fixtures never invoke a physical device or a model.
@MainActor final class WorkflowDeviceTests: XCTestCase {
    private func frame(color: UIColor = .white) -> FrameImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let bytes = UIGraphicsImageRenderer(size: .init(width: 600, height: 900), format: format).pngData { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 900))
            UIColor.black.setFill(); context.fill(CGRect(x: 220, y: 400, width: 100, height: 70))
        }
        return .init(id: UUID().uuidString, png: bytes, width: 600, height: 900, capturedAt: Date(), isDemo: true)
    }
    private func actions(_ device: WorkflowFixtureBridge, receipts: WorkflowFixtureReceipts = .init()) -> ActionCoordinator {
        .init(bridge: device, limits: .init(), approve: { request in await receipts.approve(request); return true },
              onImage: { _, _ in }, onReceipt: { _ in }, onWorkflowResult: { call, result in await receipts.append(call, result) })
    }
    private func train(_ device: WorkflowFixtureBridge) async throws -> WorkflowTrace {
        let coordinator = actions(device)
        await coordinator.configureLearning(enabled: true)
        try await coordinator.nameWorkflow("notes.create")
        _ = try await coordinator.execute(name: "list_apps", parameters: [:], callID: "apps")
        _ = try await coordinator.execute(name: "launch_app", parameters: ["bundle_id": "com.apple.mobilenotes", "purpose": "备忘录"], callID: "launch")
        _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "page")
        _ = try await coordinator.execute(name: "tap", parameters: ["x": 260, "y": 430, "purpose": "新建笔记"], callID: "tap")
        _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "focused")
        _ = try await coordinator.execute(name: "type_text", parameters: ["text": "private example", "purpose": "输入 private example"], callID: "type")
        _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "result")
        let recorded = try await coordinator.learningTrace(runID: UUID())
        return try XCTUnwrap(recorded)
    }
    private func publish(_ trace: WorkflowTrace, into store: WorkflowLibrary) async throws -> LearnedWorkflow {
        try await store.enqueue(trace, expectedEpoch: store.epoch()); try await store.processPending()
        let list = try await store.workflows(), item = try XCTUnwrap(list.first)
        try await store.activate(id: item.id, revision: item.revision)
        let active = try await store.active(); return try XCTUnwrap(active.first)
    }
    func testActualRecordedCoordinatesAreParameterizedAndReplayCommitsEachChild() async throws {
        let source = frame(), trace = try await train(WorkflowFixtureBridge(frame: source))
        XCTAssertEqual(trace.argumentKeys, ["text_1"])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(trace), as: UTF8.self).contains("private example"))
        XCTAssertEqual(trace.steps.first?.action, .tap(x: 260, y: 430))
        let library = WorkflowLibrary(directory: nil), item = try await publish(trace, into: library)
        let device = WorkflowFixtureBridge(frame: source), receipts = WorkflowFixtureReceipts(), coordinator = actions(device, receipts: receipts)
        try await coordinator.replayWorkflow(item, arguments: ["text_1": "新正文"], callID: "flow", library: library, canAccess: { true })
        let sent = await device.sent, texts = await device.texts, approvals = await receipts.approvals, completed = await receipts.completed
        XCTAssertEqual(sent, ["launch_app", "tap", "type_text"])
        XCTAssertEqual(texts, ["新正文"])
        XCTAssertEqual(approvals, ["flow.launch", "flow.step.0", "flow.step.1"])
        XCTAssertTrue(completed.contains("flow.launch")); XCTAssertTrue(completed.contains("flow.step.0")); XCTAssertTrue(completed.contains("flow.step.1"))
        let flows = try await library.active(); XCTAssertEqual(flows.first?.successfulReplays, 1)
    }
    func testChangedPageQuarantinesFlowBeforeAnyTapAndRefusesSameTaskReplay() async throws {
        let trace = try await train(WorkflowFixtureBridge(frame: frame()))
        let library = WorkflowLibrary(directory: nil), item = try await publish(trace, into: library)
        let device = WorkflowFixtureBridge(frame: frame(color: .red)), coordinator = actions(device)
        for id in ["failed", "retry"] {
            do { try await coordinator.replayWorkflow(item, arguments: ["text_1": "x"], callID: id, library: library, canAccess: { true }); XCTFail("Changed pixels must reject replay") }
            catch { XCTAssertTrue(error is AssistantError) }
        }
        let sent = await device.sent, active = try await library.active()
        XCTAssertEqual(sent, ["launch_app"]); XCTAssertTrue(active.isEmpty)
    }
    func testPageCapabilityUsesLocalPatchesWithoutOCRAndKeepsAuthorizationReceipts() async throws {
        let source = frame(), runID = UUID()
        let bounds = [InterfaceBounds(x: 20, y: 200, width: 80, height: 40), InterfaceBounds(x: 230, y: 410, width: 60, height: 40)]
        let patches = try WorkflowPixels.interfacePatches(source, bounds: bounds)
        let anchors = zip(["首页", "搜索"], bounds).enumerated().map {
            InterfaceAnchor(text: $0.element.0, bounds: $0.element.1, patch: patches[$0.offset])
        }
        let before = InterfaceSkeleton(frameID: "before", width: 600, height: 900, anchors: anchors)
        let after = InterfaceSkeleton(frameID: "after", width: 600, height: 900, anchors: anchors)
        let evidence = PageTransitionEvidence(runID: runID, appBundleID: "com.apple.mobilenotes", appVersion: "27",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString, before: before, control: anchors[1], action: .tap, after: after)
        let library = KnowledgeLibrary(directory: nil), workspace = AssistantWorkspace(directory: nil)
        try await library.enqueue(runID: runID, workspaceEpoch: workspace.epoch(), expectedEpoch: library.epoch(), userText: "进入搜索",
            providerID: UUID(), providerScope: "fixture", model: "fixture", transitions: [evidence])
        try await library.processPending(workspace: workspace) { _, _ in
            ([], [.init(evidenceID: evidence.id, pageName: "首页", function: "进入搜索", observedResult: "搜索界面")])
        }
        let candidates = try await library.capabilities(), candidate = try XCTUnwrap(candidates.first)
        try await library.activate(id: candidate.id, revision: candidate.revision)
        let active = try await library.active(), item = try XCTUnwrap(active.first)
        let device = WorkflowFixtureBridge(frame: source), receipts = WorkflowFixtureReceipts()
        let coordinator = ActionCoordinator(bridge: device, limits: .init(), approve: { request in await receipts.approve(request); return true },
            onImage: { _, _ in XCTFail("Matched page workflow must not upload images") }, onReceipt: { _ in },
            onWorkflowResult: { call, result in await receipts.append(call, result) }, textRecognizer: ForbiddenWorkflowOCR())
        _ = try await coordinator.execute(name: "list_apps", parameters: [:], callID: "apps")
        _ = try await coordinator.execute(name: "launch_app", parameters: ["bundle_id": "com.apple.mobilenotes", "purpose": "打开"], callID: "launch")
        try await coordinator.runPageSequence([.init(id: item.id, revision: item.revision)], app: "com.apple.mobilenotes", callID: "page",
            snapshot: active, library: library, canAccess: { true })
        let sent = await device.sent, approvals = await receipts.approvals, completed = await receipts.completed
        XCTAssertEqual(sent, ["launch_app", "tap"])
        XCTAssertTrue(approvals.contains("page.0.tap")); XCTAssertTrue(completed.contains("page.0.tap"))
    }
    func testVisualControlDigestChangesWithoutRetainingSurroundingImage() throws {
        let box = InterfaceBounds(x: 10, y: 10, width: 48, height: 48)
        let white = try WorkflowPixels.visualDigest(frame(), bounds: box)
        XCTAssertEqual(white.count, 64)
        XCTAssertNotEqual(white, try WorkflowPixels.visualDigest(frame(color: .red), bounds: box))
    }
    func testPixelSamplerRejectsMalformedImageAndGeometry() throws {
        let valid = frame()
        XCTAssertTrue(try WorkflowPixels.page(valid).matches(WorkflowPixels.page(valid)))
        XCTAssertThrowsError(try WorkflowPixels.page(.init(id: "bad", png: valid.png, width: 601, height: 900, capturedAt: Date(), isDemo: true)))
        XCTAssertThrowsError(try WorkflowPixels.target(valid, x: 600, y: 0))
        XCTAssertFalse(try WorkflowPixels.targetMatches(WorkflowPixels.target(valid, x: 260, y: 430), WorkflowPixels.target(valid, x: 100, y: 100)))
    }
}

private actor WorkflowFixtureReceipts {
    var approvals: [String] = []
    var completed: [String] = []
    func approve(_ request: Approval) { approvals.append(request.callID!) }
    func append(_ call: AssistantToolCall, _ result: AssistantToolResult) { if !result.isError { completed.append(call.id) } }
}
private actor WorkflowFixtureBridge: DeviceBridge {
    let frame: FrameImage
    var sent: [String] = []
    var texts: [String] = []
    init(frame: FrameImage) { self.frame = frame }
    func screenshot() async throws -> FrameImage { .init(id: UUID().uuidString, png: frame.png, width: frame.width, height: frame.height, capturedAt: Date(), isDemo: true) }
    func installedApplications() async throws -> Data { Data("[{\"bundle_id\":\"com.apple.mobilenotes\",\"version\":\"27\"}]".utf8) }
    func systemActionContext() async throws -> String { "fixture-session" }
    func authorizeSystemAction(authorizationID: String, taskScoped: Bool) async throws {}
    func systemAction(name: String, text: String, arguments: [String], imageID: String) async throws {
        sent.append(name); if name == "type_text" { texts.append(text) }
    }
    func tap(x: Int, y: Int, imageID: String) async throws { sent.append("tap") }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws { sent.append("drag") }
    func stop() async {}
}

private struct ForbiddenWorkflowOCR: ScreenTextRecognizing {
    func recognize(_ frame: FrameImage) async throws -> ScreenTextObservation {
        XCTFail("A reviewed patch workflow must not invoke OCR")
        throw AppError.invalid("Unexpected OCR")
    }
}
