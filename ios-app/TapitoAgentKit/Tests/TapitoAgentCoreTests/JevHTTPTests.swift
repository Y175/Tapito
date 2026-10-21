import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import TapitoAgentCore

private final class JevHTTPStub: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Self.lock.withLock { Self.requests.append(request); return Self.status }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("""
        {"model":"jev-1.14.0","answers":{"next_action":{"type":"choice","choice":"done","probabilities":{"tap:text-6":0.51,"done":0.48},"confidence":0.02},"operation":{"type":"choice","choice":"tap","probabilities":{"tap":0.55,"subgoal_done":0.45},"confidence":0.01},"tap_target":{"type":"choice","choice":"text-6","probabilities":{"text-6":0.01},"confidence":0.001}},"usage":{"input_tokens":20,"output_tokens":4}}
        """.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct JevHTTPTests {
    @Test @MainActor func sendsNativeChoiceJSONWithNoImageOrChatEndpoint() async throws {
        JevHTTPStub.lock.withLock { JevHTTPStub.requests = []; JevHTTPStub.status = 200 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JevHTTPStub.self]
        let client = try JevDecisionClient(baseURL: URL(string: "https://fixture.invalid/v1")!, apiKey: "synthetic", model: "jev-1.14.0", configuration: configuration)
        defer { client.cancel() }
        let choice = try await client.choose(state: ["task": .string("点击更多热搜"), "ocr": .string("更多热搜")], instructions: "选择下一步",
            options: [.init(id: "tap:text-6", description: "更多热搜"), .init(id: "done", description: "结束"), .init(id: "wait", description: "等待")])
        #expect(choice.optionID == "tap:text-6"); #expect(choice.confidence == 0.02)
        #expect(choice.responseDiagnostics?.contains("missing=1") == true)
        #expect(choice.responseDiagnostics?.contains("choice_is_max=false") == true)
        let requests = JevHTTPStub.lock.withLock { JevHTTPStub.requests }
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.path == "/v1/systemone"); #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic")
        #expect(request.value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images") == nil)
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; body.append(contentsOf: bytes.prefix(n)) }
        }
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(json.keys) == ["model", "state", "questions"])
        let questions = try #require(json["questions"] as? [String: [String: Any]])
        #expect(questions["next_action"]?["type"] as? String == "choice")
    }

    @Test @MainActor func operationAndTargetAreIndependentHeadsInOneHTTPRequest() async throws {
        JevHTTPStub.lock.withLock { JevHTTPStub.requests = []; JevHTTPStub.status = 200 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JevHTTPStub.self]
        let client = try JevDecisionClient(baseURL: URL(string: "https://fixture.invalid/v1")!,
            apiKey: "synthetic", model: "jev-1.14.0", configuration: configuration)
        defer { client.cancel() }
        let operation = JevQuestion(id: "operation", instructions: "选择操作类型",
            options: [.init(id: "tap", description: "点击"), .init(id: "subgoal_done", description: "交回")])
        let target = JevQuestion(id: "tap_target", instructions: "选择文字目标",
            options: [.init(id: "text-6", description: "更多热搜"), .init(id: "text-7", description: "搜索")])
        let result = try await client.evaluate(state: ["goal": .string("查看榜单")], questions: [operation, target])
        #expect(try result.decision(for: operation).optionID == "tap")
        #expect(try result.decision(for: target).optionID == "text-6")
        #expect(result.inputTokens == 20)
        let requests = JevHTTPStub.lock.withLock { JevHTTPStub.requests }
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; body.append(contentsOf: bytes.prefix(n)) }
        }
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let questions = try #require(json["questions"] as? [String: [String: Any]])
        #expect(Set(questions.keys) == ["operation", "tap_target"])
        #expect(questions.values.allSatisfy { $0["type"] as? String == "choice" })
        let operations = try #require(questions["operation"]?["criteria"] as? [String: String])
        #expect(Set(operations.keys) == ["tap", "subgoal_done"])
        let targets = try #require(questions["tap_target"]?["criteria"] as? [String: String])
        #expect(Set(targets.keys) == ["text-6", "text-7"])
        #expect(request.value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images") == nil)
    }

    @Test @MainActor func HTTPFailureDoesNotRetryOrReturnADefaultChoice() async throws {
        JevHTTPStub.lock.withLock { JevHTTPStub.requests = []; JevHTTPStub.status = 429 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JevHTTPStub.self]
        let client = try JevDecisionClient(baseURL: URL(string: "https://fixture.invalid/v1")!, apiKey: "synthetic", model: "jev-1.14.0", configuration: configuration)
        defer { client.cancel() }
        await #expect(throws: AssistantError.unavailable("Jev 请求失败（HTTP 429）；本次未发送设备操作。")) {
            try await client.choose(state: [:], instructions: "选择", options: [.init(id: "done", description: "结束")])
        }
        #expect(JevHTTPStub.lock.withLock { JevHTTPStub.requests.count } == 1)
    }
}
