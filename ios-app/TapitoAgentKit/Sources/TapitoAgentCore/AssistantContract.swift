import Foundation

/// Errors cross the engine/UI boundary without changing failed operations into successful ones.
public enum AssistantError: Error, LocalizedError, Equatable {
    case invalid(String), conflict, unavailable(String), busy, cancelled
    public var errorDescription: String? {
        switch self {
        case .invalid(let text), .unavailable(let text): return text
        case .conflict: return "内容已改变，请读取最新版本后重试；旧内容未覆盖。"
        case .busy: return "此 Agent 已有任务正在执行。"
        case .cancelled: return "任务已停止。"
        }
    }
}

/// JSON values keep model SDK types out of application event consumers.
public enum AssistantValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([AssistantValue]), object([String: AssistantValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let x = try? c.decode(Bool.self) { self = .bool(x) }
        else if let x = try? c.decode(Double.self) { self = .number(x) }
        else if let x = try? c.decode(String.self) { self = .string(x) }
        else if let x = try? c.decode([AssistantValue].self) { self = .array(x) }
        else { self = .object(try c.decode([String: AssistantValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let x): try c.encode(x)
        case .number(let x): try c.encode(x)
        case .bool(let x): try c.encode(x)
        case .array(let x): try c.encode(x)
        case .object(let x): try c.encode(x)
        case .null: try c.encodeNil()
        }
    }
    public var value: Any {
        switch self {
        case .string(let x): return x
        case .number(let x): return x
        case .bool(let x): return x
        case .array(let x): return x.map(\.value)
        case .object(let x): return x.mapValues(\.value)
        case .null: return NSNull()
        }
    }
}

/// A tool invocation is identified by its original call ID; it is never a replay instruction.
public struct AssistantToolCall: Sendable {
    public let id: String
    public let name: String
    public let parameters: [String: AssistantValue]
    public init(id: String, name: String, parameters: [String: AssistantValue] = [:]) {
        self.id = id; self.name = name; self.parameters = parameters
    }
}

/// Public result text and error state; image storage remains in the device adapter.
public struct AssistantToolResult: Sendable {
    public let result: String
    public let isError: Bool
    public init(result: String, isError: Bool) { self.result = result; self.isError = isError }
}

/// Provider-neutral response metadata, excluding provider internals.
public struct AssistantResponse: Sendable {
    public struct Usage: Sendable { public let totalTokens: Int; public init(totalTokens: Int) { self.totalTokens = totalTokens } }
    public let text: String
    public let reasoning: String?
    public let usage: Usage?
    public init(text: String, reasoning: String? = nil, totalTokens: Int? = nil) {
        self.text = text; self.reasoning = reasoning; self.usage = totalTokens.map { Usage(totalTokens: $0) }
    }
}

/// Ordered events understood by any presentation layer, including a future replacement UI.
public enum AssistantEvent: Sendable {
    case llmCallStarted(turn: Int)
    case llmCallCompleted(turn: Int, response: AssistantResponse)
    case streamChunk(String), reasoningChunk(String)
    case toolCallsReceived([AssistantToolCall])
    case toolExecutionStarted(call: AssistantToolCall)
    case toolExecutionFinished(call: AssistantToolCall, result: AssistantToolResult)
    /// Direct program result, with no model usage or synthetic model turn.
    case programAnswer(String)
    /// Provider stream activity without exposing routing JSON or private reasoning.
    case modelProgress
    case notice(String)
}

/// User-visible conversation history is separate from durable personal memory.
public struct AssistantMessage: Sendable {
    public let isUser: Bool
    public let text: String
    public init(isUser: Bool, text: String) { self.isUser = isUser; self.text = text }
}

/// The app supplies execution authorization; a running Swift task alone is not authorization.
@MainActor public protocol AssistantEngine: AnyObject {
    /// Executes one turn with reference context and ordered neutral events.
    func run(context: String, onEvent: @escaping @MainActor (AssistantEvent) -> Void) async throws -> String
    /// Requests cancellation; the owner still waits for the active run to drain.
    func cancel()
}

/// One independently cancellable turn. Apple UI, audio and background APIs stay outside this type.
@MainActor public final class AssistantSession {
    public enum State: Equatable { case idle, running, completed, cancelled, failed }
    public private(set) var state = State.idle
    /// Invalidated before cancellation so late callbacks cannot mutate presentation.
    private var generation = UUID()
    private var engine: (any AssistantEngine)?
    /// Serializes replacement runs until the old engine returns, even after cancel.
    private var draining = false
    public init() {}

    /// Runs once, fences late events, and retrieves only relevant reference memory.
    public func run(engine: any AssistantEngine, workspace: AssistantWorkspace?, query: String,
                    onEvent: @escaping @MainActor (AssistantEvent) -> Void) async throws -> String {
        guard !draining else { throw AssistantError.busy }
        draining = true
        defer { draining = false; self.engine = nil }
        let token = UUID(); generation = token; state = .running; self.engine = engine
        do {
            let context = try await workspace?.context(query: query) ?? ""
            try Task.checkCancellation()
            guard generation == token else { throw AssistantError.cancelled }
            let result = try await engine.run(context: context) { [weak self] event in
                guard self?.generation == token, self?.state == .running else { return }
                onEvent(event)
            }
            try Task.checkCancellation()
            guard generation == token else { throw AssistantError.cancelled }
            state = .completed; self.engine = nil
            return result
        } catch {
            engine.cancel()
            if generation == token { state = error is CancellationError ? .cancelled : .failed; self.engine = nil }
            throw error
        }
    }
    /// Invalidates the generation before cancelling the engine, so no late action can continue.
    public func cancel() { generation = UUID(); state = .cancelled; engine?.cancel(); engine = nil }
}

/// A host preflight proved that input was not dispatched and a new observation can resolve it.
public struct WorkflowCorrectionRequired: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
