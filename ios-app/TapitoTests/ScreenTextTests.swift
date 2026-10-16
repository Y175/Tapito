import XCTest
import UIKit
import SwiftAgentKit
import ProviderCore
@testable import Tapito

@MainActor final class ScreenTextTests: XCTestCase {
    private func frame(_ id: String = "fixture", blank: Bool = false, size: CGSize = .init(width: 600, height: 360)) -> FrameImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let bytes = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            if !blank {
                ("Tapito SEARCH" as NSString).draw(at: .init(x: 40, y: 50), withAttributes: [.font: UIFont.systemFont(ofSize: 42), .foregroundColor: UIColor.black])
                ("采购清单" as NSString).draw(at: .init(x: 40, y: 160), withAttributes: [.font: UIFont.systemFont(ofSize: 42), .foregroundColor: UIColor.black])
            }
        }
        return .init(id: id, png: bytes, width: Int(size.width), height: Int(size.height), capturedAt: Date(), isDemo: true)
    }
    private func coordinator(_ bridge: OCRFixtureBridge, recognizer: any ScreenTextRecognizing = StubScreenTextRecognizer()) -> ActionCoordinator {
        .init(bridge: bridge, limits: .init(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in }, textRecognizer: recognizer)
    }
    private func json(_ result: AgentToolResult) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.result.utf8)) as? [String: Any])
    }
    private func tap(_ frameID: String, id: String = "text-1") -> [String: Any] {
        ["frame_id": frameID, "candidate_id": id, "purpose": "Focus the synthetic search field"]
    }

    func testVisionReadsChineseAndEnglishInPortraitAndLandscapePixelSpace() async throws {
        let recognizer = VisionScreenTextRecognizer()
        for size in [CGSize(width: 600, height: 360), CGSize(width: 600, height: 900)] {
            let f = frame(size: size), result = try await recognizer.recognize(f)
            XCTAssertEqual(result.frameID, f.id)
            XCTAssertTrue(result.candidates.contains { $0.text.contains("Tapito") })
            XCTAssertTrue(result.candidates.contains { $0.text.contains("采购清单") })
            for candidate in result.candidates {
                XCTAssertGreaterThanOrEqual(candidate.bounds.x, 0)
                XCTAssertGreaterThanOrEqual(candidate.bounds.y, 0)
                XCTAssertLessThan(candidate.bounds.centerX, f.width)
                XCTAssertLessThan(candidate.bounds.centerY, f.height)
                if candidate.text.contains("Tapito") { XCTAssertLessThan(candidate.bounds.centerY, 130) }
            }
        }
    }
    func testVisionDistinguishesEmptyScreenFromInvalidImageAndDimensionMismatch() async throws {
        let recognizer = VisionScreenTextRecognizer()
        let empty = try await recognizer.recognize(frame(blank: true))
        XCTAssertTrue(empty.candidates.isEmpty)
        XCTAssertTrue(try empty.page(offset: 0).contains("no_text"))
        let valid = frame()
        for invalid in [FrameImage(id: "bad", png: Data(), width: 600, height: 360, capturedAt: Date(), isDemo: true),
                        FrameImage(id: "wrong-size", png: valid.png, width: 601, height: 360, capturedAt: Date(), isDemo: true)] {
            do { _ = try await recognizer.recognize(invalid); XCTFail("Invalid image cannot become no_text") }
            catch { XCTAssertTrue(error is AppError) }
        }
    }
    func testVisionBoundsConvertBottomLeftToTopLeftAndRejectInvalidGeometry() throws {
        let box = try ScreenTextCandidate.PixelBounds.convert(.init(x: 0.25, y: 0.5, width: 0.5, height: 0.25), width: 200, height: 400)
        XCTAssertEqual(box, .init(x: 50, y: 100, width: 100, height: 100))
        for invalid in [CGRect(x: -0.1, y: 0, width: 0.2, height: 0.2), CGRect(x: 0.9, y: 0, width: 0.2, height: 0.2), .zero] {
            XCTAssertThrowsError(try ScreenTextCandidate.PixelBounds.convert(invalid, width: 200, height: 400))
        }
    }
    func testOCRSendsNoImageAndVisualEscalationReusesTheExactCapturedFrame() async throws {
        let source = frame(), bridge = OCRFixtureBridge(frame: source), actions = coordinator(bridge)
        let text = try await actions.execute(name: "observe_screen", parameters: [:], callID: "ocr")
        XCTAssertTrue(text.images.isEmpty)
        let id = try XCTUnwrap(try json(text)["frame_id"] as? String)
        let visual = try await actions.execute(name: "screenshot", parameters: ["frame_id": id], callID: "vision")
        XCTAssertEqual(visual.images.map(\.data), [source.png])
        let count = await bridge.captureCount; XCTAssertEqual(count, 1)
        XCTAssertEqual(try json(visual)["image_id"] as? String, id)
    }
    func testCandidateReceiptsExplainTextLocationEligibilityWithoutClaimingClickability() throws {
        let bounds = ScreenTextCandidate.PixelBounds(x: 20, y: 20, width: 60, height: 40)
        let observation = ScreenTextObservation(frameID: "eligibility", width: 600, height: 360, candidates: [
            .init(id: "unique", text: "发现", confidence: 1, bounds: bounds),
            .init(id: "uncertain", text: "微博热搜", confidence: 0.3, bounds: bounds),
            .init(id: "duplicate-1", text: "搜索", confidence: 1, bounds: bounds),
            .init(id: "duplicate-2", text: "搜索", confidence: 1, bounds: bounds)
        ], elapsedMS: 1)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try observation.page(offset: 0).utf8)) as? [String: Any])
        let rows = try XCTUnwrap(payload["candidates"] as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["text_target"] as? String }, ["eligible", "low_confidence", "duplicate", "duplicate"])
        XCTAssertTrue((payload["notice"] as? String)?.contains("不证明可点击") == true)
        XCTAssertThrowsError(try observation.target(id: "uncertain"))
        XCTAssertThrowsError(try observation.target(id: "duplicate-1"))
        XCTAssertEqual(try observation.target(id: "unique").text, "发现")
    }
    func testCoordinateTapCannotBypassOCRAndRejectionKeepsTheSameFrameForInspection() async throws {
        let bridge = OCRFixtureBridge(frame: frame()), actions = coordinator(bridge, recognizer: StubScreenTextRecognizer(confidence: 0.3))
        let observation = try await actions.execute(name: "observe_screen", parameters: [:], callID: "ocr")
        let id = try XCTUnwrap(try json(observation)["frame_id"] as? String)
        let parameters: [String: Any] = ["x": 50, "y": 40, "purpose": "Inspect before choosing this uncertain text"]
        let tool = DeviceTool(name: "tap", coordinator: actions)
        let rejection = try await tool.execute(context: .init(callId: "bypass", toolName: "tap", parameters: parameters, state: AgentState()))
        XCTAssertTrue(rejection.isError); XCTAssertTrue(rejection.result.contains("未发送点击"))
        let unsentPoints = await bridge.points; XCTAssertTrue(unsentPoints.isEmpty)
        let visual = try await actions.execute(name: "screenshot", parameters: ["frame_id": id], callID: "inspect")
        XCTAssertEqual(visual.images.count, 1)
        _ = try await actions.execute(name: "tap", parameters: parameters, callID: "visually-chosen")
        let points = await bridge.points; XCTAssertEqual(points.count, 1)
        let count = await bridge.captureCount; XCTAssertEqual(count, 1, "A rejected unsent tap must not force a second capture")
    }
    func testDefaultVisualObservationReusesOCRAndRepeatedViewingDoesNotUploadAgain() async throws {
        let bridge = OCRFixtureBridge(frame: frame()), actions = coordinator(bridge)
        let observation = try await actions.execute(name: "observe_screen", parameters: [:], callID: "ocr")
        let id = try XCTUnwrap(try json(observation)["frame_id"] as? String)
        let first = try await actions.execute(name: "screenshot", parameters: [:], callID: "first-visual")
        XCTAssertEqual(first.images.count, 1); XCTAssertEqual(try json(first)["image_id"] as? String, id)
        XCTAssertEqual(try json(first)["observation_source"] as? String, "ocr_frame")
        let repeated = try await actions.execute(name: "screenshot", parameters: [:], callID: "repeat-visual")
        XCTAssertTrue(repeated.images.isEmpty)
        XCTAssertEqual(try json(repeated)["image_already_sent"] as? Bool, true)
        XCTAssertEqual(try json(repeated)["image_uploaded"] as? Bool, false)
        let beforeRefresh = await bridge.captureCount; XCTAssertEqual(beforeRefresh, 1)
        let refresh = try await actions.execute(name: "screenshot", parameters: ["refresh_reason": "A loading animation changed the page"], callID: "refresh")
        XCTAssertEqual(refresh.images.count, 1)
        XCTAssertNotEqual(try json(refresh)["image_id"] as? String, id)
        XCTAssertEqual(try json(refresh)["observation_source"] as? String, "fresh_capture")
        let afterRefresh = await bridge.captureCount; XCTAssertEqual(afterRefresh, 2)
        do { _ = try await actions.execute(name: "screenshot", parameters: ["frame_id": id], callID: "stale"); XCTFail("Refresh consumes the old OCR frame") } catch {}
    }
    func testLowConfidenceTextRejectionKeepsObservationButAChangedFrameCannotUseOldVisualGrant() async throws {
        let bridge = OCRFixtureBridge(frame: frame()), actions = coordinator(bridge, recognizer: StubScreenTextRecognizer(confidence: 0.3))
        let observation = try await actions.execute(name: "observe_screen", parameters: [:], callID: "ocr")
        let id = try XCTUnwrap(try json(observation)["frame_id"] as? String)
        let rejection = try await DeviceTool(name: "tap_text", coordinator: actions).execute(context: .init(callId: "low", toolName: "tap_text", parameters: tap(id), state: AgentState()))
        XCTAssertTrue(rejection.isError)
        _ = try await actions.execute(name: "screenshot", parameters: ["frame_id": id], callID: "visual")
        _ = try await actions.execute(name: "observe_screen", parameters: [:], callID: "changed")
        do { _ = try await actions.execute(name: "tap", parameters: ["x": 50, "y": 40, "purpose": "Old visual coordinates"], callID: "stale-tap"); XCTFail("New OCR cannot inherit the old frame's visual grant") } catch {}
        let points = await bridge.points; XCTAssertTrue(points.isEmpty)
    }
    func testScreenshotRejectsFrameSelectionCombinedWithRefreshReasonBeforeCapturing() async throws {
        let bridge = OCRFixtureBridge(frame: frame()), actions = coordinator(bridge)
        do {
            _ = try await actions.execute(name: "screenshot", parameters: ["frame_id": "old", "refresh_reason": "Changed page"], callID: "contradictory")
            XCTFail("A request must select one observation source")
        } catch {}
        let count = await bridge.captureCount; XCTAssertEqual(count, 0)
    }
    func testOCRInputUsesExistingAuthorizationAndInvalidatesCandidatesBeforeAnotherInput() async throws {
        let bridge = OCRFixtureBridge(frame: frame()), actions = coordinator(bridge)
        let text = try await actions.execute(name: "observe_screen", parameters: [:], callID: "o")
        let id = try XCTUnwrap(try json(text)["frame_id"] as? String)
        _ = try await actions.execute(name: "tap_text", parameters: tap(id), callID: "t")
        let points = await bridge.points
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.0, try Wire.normalized(pixel: 50, dimension: 600))
        XCTAssertEqual(points.first?.1, try Wire.normalized(pixel: 40, dimension: 360))
        do { _ = try await actions.execute(name: "tap_text", parameters: tap(id), callID: "repeat"); XCTFail("Old OCR cannot repeat input") } catch {}
        do { _ = try await actions.execute(name: "screenshot", parameters: ["frame_id": id], callID: "old"); XCTFail("Changed page cannot send the old OCR frame") } catch {}
        _ = try await actions.execute(name: "type_text", parameters: ["text": "牛肉面🙂", "purpose": "Insert exact requested text"], callID: "text")
        let inserted = await bridge.text; XCTAssertEqual(inserted, "牛肉面🙂")
        let count = await bridge.captureCount; XCTAssertEqual(count, 1, "Focused input needs no extra screenshot")
    }
    func testDuplicateLowConfidenceAndOtherFrameCandidatesNeverDispatch() async throws {
        for recognizer in [StubScreenTextRecognizer(duplicate: true), StubScreenTextRecognizer(confidence: 0.4)] {
            let bridge = OCRFixtureBridge(frame: frame()), actions = coordinator(bridge, recognizer: recognizer)
            let text = try await actions.execute(name: "observe_screen", parameters: [:], callID: "o")
            let id = try XCTUnwrap(try json(text)["frame_id"] as? String)
            for parameters in [tap(id), tap("other-frame"), tap(id, id: "invented")] {
                do { _ = try await actions.execute(name: "tap_text", parameters: parameters, callID: UUID().uuidString); XCTFail() } catch {}
            }
            let points = await bridge.points; XCTAssertTrue(points.isEmpty)
        }
    }
    func testRecognitionFailureAndCaptureFailureRemainErrorsWithoutModelFallback() async throws {
        for failure in [true, false] {
            let bridge = OCRFixtureBridge(frame: frame(), captureFails: failure)
            let actions = coordinator(bridge, recognizer: StubScreenTextRecognizer(fails: true))
            let tool = DeviceTool(name: "observe_screen", coordinator: actions)
            let result = try await tool.execute(context: .init(callId: "error", toolName: "observe_screen", parameters: [:], state: AgentState()))
            XCTAssertTrue(result.isError); XCTAssertTrue(result.images.isEmpty)
            XCTAssertFalse(result.result.contains("no_text"))
            XCTAssertTrue(result.result.contains(failure ? "Capture fixture failure" : "OCR fixture failure"))
            let count = await bridge.captureCount; XCTAssertEqual(count, 1)
        }
    }
    func testVideoPreparationFailureStopsRepeatedOCRVisualCaptureAndInputInTheSameRun() async throws {
        let bridge = OCRFixtureBridge(frame: frame(), captureUnavailable: true), actions = coordinator(bridge)
        for name in ["observe_screen", "screenshot", "observe_screen", "home", "type_text"] {
            let result = try await DeviceTool(name: name, coordinator: actions).execute(context: .init(callId: UUID().uuidString, toolName: name, parameters: [:], state: AgentState()))
            XCTAssertTrue(result.isError); XCTAssertTrue(result.images.isEmpty)
            XCTAssertTrue(result.result.contains("OCR 未开始"))
        }
        let count = await bridge.captureCount; XCTAssertEqual(count, 1, "OCR and screenshot must share the failed video-session state")
        let points = await bridge.points; XCTAssertTrue(points.isEmpty)
        let inserted = await bridge.text; XCTAssertTrue(inserted.isEmpty)
        // A separate explicit run may try again; there is no timer, reconnect or replay here.
        let next = coordinator(bridge)
        let result = try await DeviceTool(name: "observe_screen", coordinator: next).execute(context: .init(callId: "new-run", toolName: "observe_screen", parameters: [:], state: AgentState()))
        XCTAssertTrue(result.isError)
        let afterNewRun = await bridge.captureCount; XCTAssertEqual(afterNewRun, 2)
    }
    func testStopDuringRecognitionCannotPublishCandidatesOrDispatch() async throws {
        let bridge = OCRFixtureBridge(frame: frame()), actions = coordinator(bridge, recognizer: StubScreenTextRecognizer(delay: true))
        let pending = Task { try await actions.execute(name: "observe_screen", parameters: [:], callID: "o") }
        try await Task.sleep(for: .milliseconds(20)); await actions.stop()
        do { _ = try await pending.value; XCTFail("Stopped recognition cannot publish") } catch {}
        do { _ = try await actions.execute(name: "tap_text", parameters: tap("frame-1"), callID: "t"); XCTFail() } catch {}
        let points = await bridge.points; XCTAssertTrue(points.isEmpty)
    }
    func testOCRPaginationPreservesAllCandidatesAndNeverRecaptures() async throws {
        let bridge = OCRFixtureBridge(frame: frame()), actions = coordinator(bridge, recognizer: StubScreenTextRecognizer(count: 100))
        var response = try await actions.execute(name: "observe_screen", parameters: [:], callID: "o")
        var seen: [String] = []
        while true {
            XCTAssertLessThanOrEqual(response.result.count, 6_000)
            let object = try json(response), rows = try XCTUnwrap(object["candidates"] as? [[String: Any]])
            seen += rows.compactMap { $0["id"] as? String }
            guard let next = object["next_offset"] as? Int else { break }
            response = try await actions.execute(name: "observe_screen", parameters: ["frame_id": try XCTUnwrap(object["frame_id"]), "offset": next], callID: "page-\(next)")
        }
        XCTAssertEqual(seen.count, 100); XCTAssertEqual(Set(seen).count, 100)
        let count = await bridge.captureCount; XCTAssertEqual(count, 1)
    }
    func testActualAgentReadsOCRAndTypesIntoFocusedFieldWithoutSendingScreenImages() async throws {
        let bridge = OCRFixtureBridge(frame: frame())
        let model = AgentSessionController(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
            runServices: .init(execution: .reactFixture, provider: OCRFlowProvider(), bridge: bridge))
        let id = model.createConversation(mode: .live); defer { model.stop() }
        XCTAssertTrue(model.send("Read the screen, then enter 牛肉面🙂 into the already focused synthetic field", in: id, cloudConsent: true))
        for _ in 0..<200 where model.running {
            // This synthetic bridge uses per-action approval, just like other non-NCM routes.
            if model.approval != nil { model.approve(true) }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(model.running)
        XCTAssertEqual(model.sessions.conversation(id)?.phase, .completed)
        let tools = model.sessions.conversation(id)?.messages.compactMap(\.tool) ?? []
        XCTAssertEqual(tools.map(\.name), ["observe_screen", "type_text"])
        XCTAssertTrue(tools.allSatisfy { $0.state == .succeeded }, tools.map { "\($0.name): \($0.state) \($0.result)" }.joined(separator: " | "))
        let inserted = await bridge.text; XCTAssertEqual(inserted, "牛肉面🙂")
        let count = await bridge.captureCount; XCTAssertEqual(count, 1)
        let points = await bridge.points; XCTAssertTrue(points.isEmpty, "An already focused field needs no coordinate tap")
    }
}

private struct StubScreenTextRecognizer: ScreenTextRecognizing {
    var duplicate = false, confidence: Float = 0.97, fails = false, delay = false, count = 1
    func recognize(_ frame: FrameImage) async throws -> ScreenTextObservation {
        if delay { try await Task.sleep(for: .milliseconds(100)) }
        if fails { throw AppError.unavailable("OCR fixture failure") }
        return .init(frameID: frame.id, width: frame.width, height: frame.height,
            candidates: (0..<(duplicate ? 2 : count)).map { .init(id: "text-\($0 + 1)", text: duplicate ? "搜索" : "Target \($0)",
                confidence: confidence, bounds: .init(x: 20, y: 20, width: 60, height: 40)) }, elapsedMS: 1)
    }
}
private actor OCRFixtureBridge: DeviceBridge {
    let source: FrameImage, captureFails: Bool, captureUnavailable: Bool
    var captureCount = 0, points: [(Int, Int)] = [], text = ""
    init(frame: FrameImage, captureFails: Bool = false, captureUnavailable: Bool = false) {
        source = frame; self.captureFails = captureFails; self.captureUnavailable = captureUnavailable
    }
    func screenshot() throws -> FrameImage {
        captureCount += 1
        if captureUnavailable { throw AppError.screenCaptureUnavailable("屏幕视频会话启动失败；OCR 未开始；本次未发送触控输入") }
        if captureFails { throw AppError.unavailable("Capture fixture failure") }
        return .init(id: "frame-\(captureCount)", png: source.png, width: source.width, height: source.height, capturedAt: Date(), isDemo: true)
    }
    func tap(x: Int, y: Int, imageID: String) { points.append((x, y)) }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) {}
    func systemActionContext() -> String { "synthetic-session" }
    func authorizeSystemAction(authorizationID: String, taskScoped: Bool) {}
    func systemAction(name: String, text: String, arguments: [String], imageID: String) { self.text = text }
    func stop() {}
}
private struct OCRFlowProvider: ModelProvider {
    static let name = "ocr-offline-flow"
    let configuration = ProviderConfiguration(name: name, baseURL: URL(string: "https://fixture.invalid")!, defaultModel: "fixture")
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        XCTAssertTrue(request.messages.allSatisfy { $0.images.isEmpty }, "Local OCR pixels must never reach the provider")
        let results = request.messages.filter { $0.role == .tool }
        let call: ModelToolCall
        switch results.count {
        case 0: call = .init(id: "ocr", name: "observe_screen", arguments: "{}")
        case 1:
            // The real agent prefixes provider tool messages with its explicit status receipt.
            let receipt = results[0].content.components(separatedBy: "\n")
            XCTAssertEqual(receipt.first, "[Tool: observe_screen] OK")
            let payload = receipt.dropFirst().joined(separator: "\n")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
            let candidates = try XCTUnwrap(object["candidates"] as? [[String: Any]])
            XCTAssertTrue(candidates.contains { ($0["text"] as? String)?.contains("Tapito SEARCH") == true })
            // Vision confidence varies across OS/hardware. Low-confidence text must
            // not be clicked; that safety contract is covered by the locator tests.
            // This fixture models an already focused field, so whole-string input
            // needs no coordinate target or fabricated confidence upgrade.
            call = .init(id: "text", name: "type_text", arguments: "{\"text\":\"牛肉面🙂\",\"purpose\":\"Insert exact text into the already focused fixture field\"}")
        default: return .init(text: "Text delivery acknowledged; visual acceptance not asserted.", finishReason: .stop, request: request, providerName: Self.name)
        }
        return .init(text: "", finishReason: .toolCalls, toolCalls: [call], request: request, providerName: Self.name)
    }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await complete(request)
                    for call in response.toolCalls { continuation.yield(.toolCall(call)) }
                    if !response.text.isEmpty { continuation.yield(.text(response.text)) }
                    continuation.yield(.finish(reason: response.finishReason, usage: nil)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
