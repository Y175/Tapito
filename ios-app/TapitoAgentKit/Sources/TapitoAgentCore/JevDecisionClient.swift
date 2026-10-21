import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A closed-set action whose identifier is bound to parameters by the host.
public struct JevOption: Sendable {
    /// Unique within this decision; never a coordinate or executable instruction.
    public let id: String
    /// Model-visible meaning of this action.
    public let description: String
    public init(id: String, description: String) { self.id = id; self.description = description }
}

/// The highest-probability action and diagnostics; confidence is not an execution gate.
public struct JevDecision: Sendable {
    /// Identifier of the local action with the highest returned probability.
    public let optionID: String
    /// Returned probability, without normalization or a minimum threshold.
    public let probability: Double
    /// Provider metadata only; never used to allow or reject an action.
    public let confidence: Double
    /// Model reported by the provider.
    public let model: String
    /// Provider-reported input token count.
    public let inputTokens: Int
    /// Provider-reported output token count.
    public let outputTokens: Int
    /// Structural response diagnostics; excludes screen text and upstream identifiers.
    public let responseDiagnostics: String?
    public init(optionID: String, probability: Double, confidence: Double, model: String,
                inputTokens: Int, outputTokens: Int, responseDiagnostics: String? = nil) {
        self.optionID = optionID; self.probability = probability; self.confidence = confidence
        self.model = model; self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.responseDiagnostics = responseDiagnostics
    }
}

/// Native TypeSafe decisions stay separate from generative chat/model SDK contracts.
@MainActor public protocol JevDecisionProviding: AnyObject {
    /// Evaluates independent closed-set questions against the same observation.
    func evaluate(state: [String: AssistantValue], questions: [JevQuestion]) async throws -> JevEvaluation
    /// Cancels outstanding requests; the owner creates a new client for another task.
    func cancel()
}

/// A named closed-set question; operation and target questions can share one HTTP request.
public struct JevQuestion: Sendable {
    /// Response key, unique within one request.
    public let id: String
    /// Semantics of this decision, independent of app-specific button names.
    public let instructions: String
    /// Host-bound alternatives; each question supports up to 255 options.
    public let options: [JevOption]
    public init(id: String, instructions: String, options: [JevOption]) {
        self.id = id; self.instructions = instructions; self.options = options
    }
}

/// One inference result. Only the selected operation's target answer is consumed.
public struct JevEvaluation: Sendable {
    /// Actual model reported in this inference response.
    public let model: String
    /// Total provider-reported input tokens for all questions.
    public let inputTokens: Int
    /// Total provider-reported output tokens for all questions.
    public let outputTokens: Int
    /// Retained only for decoding selected answers; never copied into diagnostics.
    private let data: Data

    /// Parses response metadata once; individual heads are validated only when consumed.
    public init(data: Data) throws {
        struct Header: Decodable {
            struct Usage: Decodable { let input_tokens: Int; let output_tokens: Int }
            let model: String; let usage: Usage
        }
        do {
            let header = try JSONDecoder().decode(Header.self, from: data)
            model = header.model; inputTokens = header.usage.input_tokens; outputTokens = header.usage.output_tokens
            self.data = data
        } catch {
            throw AssistantError.invalid("Jev 响应 JSON 字段无法解析；没有发送设备操作。")
        }
    }

    /// Missing or malformed unused heads never substitute a different operation.
    @MainActor public func decision(for question: JevQuestion) throws -> JevDecision {
        try JevDecisionClient.decode(data, options: question.options, questionID: question.id)
    }
}

public extension JevDecisionProviding {
    /// Single-question convenience used by closed-set callers and contract tests.
    func choose(state: [String: AssistantValue], instructions: String, options: [JevOption]) async throws -> JevDecision {
        let question = JevQuestion(id: "next_action", instructions: instructions, options: options)
        return try await evaluate(state: state, questions: [question]).decision(for: question)
    }
}

/// Text-only TypeSafe client. No images, generative calls, confidence thresholds or hidden retries.
@MainActor public final class JevDecisionClient: JevDecisionProviding {
    private let endpoint: URL
    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let redirectGuard = JevRedirectGuard()

    /// The app validates endpoint policy before construction; tests may inject a URLProtocol session configuration.
    public init(baseURL: URL, apiKey: String, model: String, configuration: URLSessionConfiguration = .ephemeral) throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AssistantError.invalid("请配置 Jev API 密钥和模型 ID。")
        }
        endpoint = baseURL.appendingPathComponent("systemone"); self.apiKey = apiKey; self.model = model
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 90
        session = URLSession(configuration: configuration, delegate: redirectGuard, delegateQueue: nil)
    }
    /// Releases the run-scoped HTTP session and cancels outstanding inference.
    public func cancel() { session.invalidateAndCancel() }
    deinit { session.invalidateAndCancel() }

    /// Sends one native multi-question request, without retries or image payloads.
    public func evaluate(state: [String: AssistantValue], questions: [JevQuestion]) async throws -> JevEvaluation {
        try Task.checkCancellation()
        guard !questions.isEmpty, Set(questions.map(\.id)).count == questions.count,
              questions.allSatisfy({ !$0.options.isEmpty && $0.options.count <= 255 && Set($0.options.map(\.id)).count == $0.options.count }) else {
            throw AssistantError.invalid("Jev Choice 需要 1–255 个唯一候选。")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "state": state.mapValues(\.value),
            "questions": Dictionary(uniqueKeysWithValues: questions.map { question in
                (question.id, ["type": "choice", "instructions": question.instructions,
                    "criteria": Dictionary(uniqueKeysWithValues: question.options.map { ($0.id, $0.description) })] as [String: Any])
            })
        ], options: [.sortedKeys])
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw AssistantError.invalid("Jev 未返回 HTTP 响应。") }
        guard (200..<300).contains(http.statusCode) else {
            // Do not persist an upstream body that may echo private screen data or credentials.
            throw AssistantError.unavailable("Jev 请求失败（HTTP \(http.statusCode)）；本次未发送设备操作。")
        }
        return try JevEvaluation(data: data)
    }

    /// Rank returned probabilities directly. Distribution coverage, normalization and `choice`
    /// consistency are diagnostics, not execution gates; the winning ID must bind a local action.
    public static func decode(_ data: Data, options: [JevOption], questionID: String = "next_action") throws -> JevDecision {
        struct Answer: Decodable { let type: String; let choice: String; let probabilities: [String: Double]; let confidence: Double }
        struct Usage: Decodable { let input_tokens: Int; let output_tokens: Int }
        struct Response: Decodable { let model: String; let answers: [String: AssistantValue]; let usage: Usage }
        let value: Response
        let answer: Answer
        do {
            value = try JSONDecoder().decode(Response.self, from: data)
            guard let raw = value.answers[questionID] else {
                throw AssistantError.invalid("Jev 未返回 \(questionID) 的 Choice 答案；没有发送设备操作。")
            }
            answer = try JSONDecoder().decode(Answer.self, from: JSONEncoder().encode(raw))
        }
        catch is DecodingError {
            // Do not copy the raw body or decoding context, which may contain screen text.
            throw AssistantError.invalid("Jev 响应 JSON 字段无法解析；没有发送设备操作。")
        }
        guard answer.type == "choice" else {
            throw AssistantError.invalid("Jev 未返回 \(questionID) 的 Choice 答案；没有发送设备操作。")
        }
        guard !answer.probabilities.isEmpty, answer.probabilities.values.allSatisfy(\.isFinite) else {
            throw AssistantError.invalid("Jev 没有可排序的概率结果；没有发送设备操作。")
        }
        let highest = answer.probabilities.values.max()!
        // Rank before binding: never silently replace an unknown winner with the runner-up.
        let winners = Set(answer.probabilities.filter { $0.value == highest }.map(\.key))
        let selectedID: String
        if winners.contains(answer.choice) {
            selectedID = answer.choice
        } else if let tiedOption = options.first(where: { winners.contains($0.id) }) {
            // Equal maxima use request order when the provider's choice is not a maximum.
            selectedID = tiedOption.id
        } else {
            throw AssistantError.invalid("Jev 最高概率选项不属于本轮候选；没有发送设备操作。")
        }
        guard options.contains(where: { $0.id == selectedID }) else {
            throw AssistantError.invalid("Jev 最高概率选项不属于本轮候选；没有发送设备操作。")
        }
        let expected = Set(options.map(\.id)), returned = Set(answer.probabilities.keys)
        let diagnostics = "expected=\(expected.count) returned=\(returned.count) missing=\(expected.subtracting(returned).count) extra=\(returned.subtracting(expected).count) probability_sum=\(answer.probabilities.values.reduce(0, +)) choice_is_max=\(winners.contains(answer.choice))"
        return .init(optionID: selectedID, probability: highest, confidence: answer.confidence,
                     model: value.model, inputTokens: value.usage.input_tokens, outputTokens: value.usage.output_tokens,
                     responseDiagnostics: diagnostics)
    }

}

private final class JevRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
