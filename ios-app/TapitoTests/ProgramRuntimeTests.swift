import XCTest
import ProviderCore
import TapitoAgentCore
@testable import Tapito

/// Exercises the production program runtime through the host composition, without device/network access.
@MainActor final class ProgramRuntimeTests: XCTestCase {
    func testConversationRoutesThroughProgramRuntimeWithNoDeviceTools() async throws {
        let store = ConversationStore(inMemory: true), workspace = AssistantWorkspace(directory: nil)
        try await workspace.setAutomaticMemory(false)
        let model = AgentSessionController(sessions: store, loadPersistentState: false,
            runServices: .init(provider: ProgramConversationFixture(), bridge: UnavailableBridge()), workspace: workspace)
        let id = model.createConversation(mode: .live)
        XCTAssertTrue(model.send("你好", in: id, cloudConsent: true))
        for _ in 0..<150 where model.running { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.running)
        XCTAssertEqual(store.conversation(id)?.phase, .completed)
        XCTAssertEqual(store.conversation(id)?.messages.last(where: { $0.role == .assistant })?.text, "你好，Tapito。")
        XCTAssertFalse(store.conversation(id)?.messages.contains(where: { $0.tool != nil }) == true)
    }
    func testDeferredLearningScopeChangesWithEndpointAndAccount() {
        var profile = ProviderProfile(name: "fixture")
        let original = profile.learningScope
        profile.settings.baseURL = "https://other.invalid/v1"
        XCTAssertNotEqual(original, profile.learningScope)
        let endpoint = profile.learningScope
        profile.keyAccount = "another-account"
        XCTAssertNotEqual(endpoint, profile.learningScope)
    }
}
private struct ProgramConversationFixture: ModelProvider {
    static let name = "program-conversation-fixture"
    let configuration = ProviderConfiguration(name: name, baseURL: URL(string: "https://fixture.invalid")!)
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        if request.tools.contains(where: { $0.name == "route_task" }) {
            let json = """
            {"kind":"conversation","target_mode":"none","app_bundle_id":null,"app_name":null,"skill_ids":[],"flow_id":null,"flow_revision":null,"texts":[],"page_calls":[],"requires_summary":false,"completion_kind":"conversation","question":null}
            """
            return .init(text: "", finishReason: .toolCalls, toolCalls: [.init(id: "route", name: "route_task", arguments: json)], request: request, providerName: Self.name)
        }
        return .init(text: "你好，Tapito。", finishReason: .stop, request: request, providerName: Self.name)
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
