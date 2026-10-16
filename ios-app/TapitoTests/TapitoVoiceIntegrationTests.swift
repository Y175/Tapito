import ActivityKit
import XCTest
@testable import Tapito

@MainActor final class TapitoVoiceIntegrationTests: XCTestCase {
    func testVoiceReceiptContainsOutcomeButNotToolTextOrReasoning() throws {
        let store = ConversationStore(inMemory: true)
        let id = store.create(mode: .live)
        let run = try XCTUnwrap(store.begin(in: id, query: "创建采购清单"))
        store.updateTool(callID: "private-id", name: "type_text", state: .outcomeUnknown,
                         result: "private-tool-result", identity: run)
        store.completeAssistantTurn("", reasoning: "private-reasoning", identity: run)
        store.finish(run, phase: .stopped, summary: "已停止")
        let receipt = try XCTUnwrap(store.voiceContinuationReceipt(in: id))
        XCTAssertTrue(receipt.contains("结果未知"))
        XCTAssertTrue(receipt.contains("禁止自动重发"))
        XCTAssertFalse(receipt.contains("private-"))
        XCTAssertFalse(receipt.contains("创建采购清单"))
    }

    func testVoiceSessionReservesSubmissionFromOtherTextEntries() {
        let store = ConversationStore(inMemory: true)
        let model = AgentSessionController(sessions: store, loadPersistentState: false)
        let voice = model.createConversation(mode: .demo)
        let other = model.createConversation(mode: .demo)
        model.voiceConversationID = voice
        XCTAssertFalse(model.send("不能插队", in: other))
        XCTAssertFalse(model.send("不能绕过语音协调器", in: voice))
        XCTAssertTrue(store.activeRuns.isEmpty)
    }

    func testVoiceActivityNavigatesToActualTurnAndNeverInventsFirstTurn() throws {
        let conversation = UUID(), voice = UUID(), run = UUID(), approval = UUID()
        let attributes = AgentActivityAttributes(sessionID: conversation, runID: voice, isDemo: false)
        var content = AgentActivityAttributes.ContentState(phase: .listening, completedTools: 0,
            updatedAt: Date(), isVoiceSession: true)
        XCTAssertNil(content.route(attributes: attributes))
        content.voiceRunID = run; content.approvalID = approval
        let route = try XCTUnwrap(content.route(attributes: attributes))
        XCTAssertEqual(route.runID, run)
        XCTAssertEqual(route.sessionID, conversation)
        XCTAssertEqual(route.approvalID, approval)
        XCTAssertEqual(route.url.scheme, "tapito")
        XCTAssertEqual(AgentActivityRoute(url: route.url), route)
    }

    func testIslandEndUsesProjectedVoiceSessionNotTaskOrResidentIdentity() {
        let resident = AgentActivityAttributes(sessionID: UUID(), runID: UUID(), isDemo: false)
        let voice = UUID(), turn = UUID()
        var state = AgentActivityAttributes.ContentState(phase: .listening, completedTools: 0,
            updatedAt: Date(), runID: voice, isVoiceSession: true, voiceRunID: turn)
        XCTAssertEqual(state.activeVoiceSessionID(attributes: resident), voice)
        state.phase = .stopped
        XCTAssertNil(state.activeVoiceSessionID(attributes: resident))
        state.phase = .thinking; state.isVoiceSession = false
        XCTAssertNil(state.activeVoiceSessionID(attributes: resident))
    }

    func testColdBackgroundVoiceRequiresOwnedConversationAndStillRejectsText() {
        let store = ConversationStore(inMemory: true)
        let model = AgentSessionController(sessions: store, loadPersistentState: false)
        model.setForeground(false)
        let voice = model.createConversation(mode: .demo)
        model.voiceConversationID = voice
        XCTAssertFalse(model.send("尚未收音", in: voice, allowBackgroundStart: true, voiceTurn: true))
        model.executionModel(for: voice).voiceManaged = true
        model.voiceCaptureActive = false
        XCTAssertFalse(model.send("文字不可借用语音会话资格", in: voice, allowBackgroundStart: true))
        XCTAssertTrue(model.send("合成语音轮次", in: voice, allowBackgroundStart: true, voiceTurn: true))
        model.stop()
    }
}
