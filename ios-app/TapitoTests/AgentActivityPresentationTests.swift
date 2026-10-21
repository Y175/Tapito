import XCTest
#if !TAPITO_PRESENTATION_HOST_TESTS
@testable import Tapito
#endif

final class AgentActivityPresentationTests: XCTestCase {
    func testLiveActivityProjectionContracts() throws {
        var state = AgentActivityAttributes.ContentState(phase: .thinking, completedTools: 2,
                                                        updatedAt: Date(), step: .verifying)
        var view = AgentActivityPresentation(state: state)
        XCTAssertTrue(view.isBusy)
        XCTAssertEqual(view.compactTitle, "核验")
        XCTAssertEqual(view.title, "检查操作结果")
        let key = view.animationKey
        state.updatedAt = Date().addingTimeInterval(12)
        view = .init(state: state)
        XCTAssertEqual(view.animationKey, key, "Heartbeats must not restart animations")
        state.step = .correcting
        view = .init(state: state)
        XCTAssertNotEqual(view.animationKey, key)
        XCTAssertEqual(view.compactTitle, "纠错")
        XCTAssertEqual(view.title, "调整后续步骤")

        state.phase = .working; state.operation = .ocr; state.step = .observing
        view = .init(state: state)
        XCTAssertEqual(view.title, "本机识别文字")
        XCTAssertEqual(view.compactTitle, "观察")
        XCTAssertEqual(view.detail, "已处理 2 项工具调用")
        let stale = AgentActivityPresentation(state: state, isStale: true)
        XCTAssertFalse(stale.isBusy)
        XCTAssertNil(stale.step)
        XCTAssertTrue(stale.needsAttention)
        XCTAssertEqual(stale.title, "状态待核对")

        // Approval, voice and terminal states may still carry a previous operation.
        state.operation = .tap; state.step = .acting
        for phase in [AgentActivityAttributes.Phase.awaitingApproval, .approved, .paused, .completed, .stopped, .blocked, .interrupted, .listening, .speaking] {
            state.phase = phase; view = .init(state: state)
            XCTAssertFalse(view.isBusy)
            XCTAssertNil(view.step)
            XCTAssertEqual(view.title, phase.title)
            XCTAssertEqual(view.symbol, phase.symbol)
        }
        for phase in [AgentActivityAttributes.Phase.listening, .speaking, .voicePreparing] {
            state.phase = phase; state.operation = nil; state.step = nil
            view = .init(state: state)
            XCTAssertNil(view.step)
            XCTAssertEqual(view.compactTitle, state.compactTitle)
        }
        state.phase = .completed
        view = .init(state: state, isStale: true)
        XCTAssertFalse(view.needsAttention, "Completion must not become stale-running")
        XCTAssertFalse(view.isBusy)

        state.phase = .working; state.step = nil; state.operation = .processing
        view = .init(state: state)
        XCTAssertNil(view.step, "Unknown tools must not invent an execution stage")
        XCTAssertEqual(view.compactTitle, "处理")

        let decoded = try JSONDecoder().decode(AgentActivityAttributes.ContentState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
        let attributes = AgentActivityAttributes(sessionID: UUID(), runID: UUID(), isDemo: false)
        state.isVoiceSession = true; state.voiceRunID = UUID(); state.phase = .listening
        XCTAssertEqual(state.activeVoiceSessionID(attributes: attributes), attributes.runID)
        XCTAssertEqual(state.route(attributes: attributes)?.runID, state.voiceRunID)
        state.phase = .stopped
        XCTAssertNil(state.activeVoiceSessionID(attributes: attributes))
    }
}
