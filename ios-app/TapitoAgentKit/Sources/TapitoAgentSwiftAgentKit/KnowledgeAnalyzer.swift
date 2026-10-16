import Foundation
import ProviderCore
import TapitoAgentCore

/// Independent M6/M7 worker. No tool executor or device reference is available to this object.
public enum KnowledgeAnalyzer {
    public static func analyze(job: AssistantLearningJob, memories: [AssistantMemory], provider: any ModelProvider, pageProvider: any ModelProvider,
                               maxTokens: Int) async throws -> ([MemoryProposal], [CapabilityAnnotation]) {
        try job.validate()
        var messages: [ModelMessage] = [.system(WorkflowPrompts.common)]
        var activeProvider = provider
        func data<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
        func envelope(_ role: String, _ payload: [String: Any]) throws -> ModelMessage {
            .user(String(decoding: try JSONSerialization.data(withJSONObject: ["role": role, "payload": payload], options: [.sortedKeys]), as: UTF8.self))
        }
        func response(tool: String, prompt: String, payload: [String: Any], properties: [String: Any]) async throws -> ModelToolCall {
            messages.append(try envelope(tool == "store_memory_proposals" ? "M6" : "M7", payload.merging(["instruction": prompt]) { _, b in b }))
            let schema: [String: Any] = ["type": "object", "properties": properties, "required": Array(properties.keys), "additionalProperties": false]
            let result: ModelResponse
            do {
                result = try await activeProvider.complete(.init(model: job.model, messages: messages, maxTokens: maxTokens,
                    tools: [.init(name: tool, description: prompt, parameters: schema)]))
            } catch {
                if Task.isCancelled || error is CancellationError { throw error }
                throw AssistantError.unavailable("异步节点 \(tool == "store_memory_proposals" ? "M6" : "M7") 请求失败：" + error.localizedDescription)
            }
            try Task.checkCancellation()
            guard result.status == .completed, result.finishReason != .length, result.finishReason != .contentFilter, result.toolCalls.count == 1,
                  let call = result.toolCalls.first, call.name == tool else {
                throw AssistantError.invalid("异步学习模型未返回完整的 \(tool) 契约。")
            }
            messages.append(.assistant(content: result.text, toolCalls: result.toolCalls, replayState: result.replayState))
            messages.append(.tool("候选结构由程序校验；尚未发布。", toolCallId: call.id))
            return call
        }
        let text: [String: Any] = ["type": "string"]
        let memoryFields: [String: Any] = ["key": text, "content": text, "scope": text, "evidence": text,
                                          "revision": ["type": ["string", "null"]]]
        let memoryCall = try await response(tool: "store_memory_proposals", prompt: WorkflowPrompts.memory,
            payload: ["user_text": job.userText, "existing_memories": try data(memories)],
            properties: ["memories": ["type": "array", "items": ["type": "object", "properties": memoryFields,
                "required": Array(memoryFields.keys), "additionalProperties": false]]])
        struct Memories: Decodable { let memories: [MemoryProposal] }
        let facts = try JSONDecoder().decode(Memories.self, from: Data(memoryCall.arguments.utf8)).memories
        guard !job.transitions.isEmpty else { return (facts, []) }
        // M7 never sees M6's personal source text, even through a provider's response-chain history.
        activeProvider = pageProvider; messages = [.system(WorkflowPrompts.common)]
        let pageFields: [String: Any] = ["evidenceID": text, "pageName": text, "function": text, "observedResult": text]
        let pageCall = try await response(tool: "store_page_candidates", prompt: WorkflowPrompts.learning,
            payload: ["transitions": try data(job.transitions.map { item in
                func stripped(_ page: InterfaceSkeleton) -> InterfaceSkeleton {
                    .init(frameID: page.frameID, width: page.width, height: page.height,
                          anchors: page.anchors.map { .init(text: $0.text, bounds: $0.bounds) })
                }
                return PageTransitionEvidence(id: item.id, runID: item.runID, appBundleID: item.appBundleID,
                    appVersion: item.appVersion, systemVersion: item.systemVersion, before: stripped(item.before),
                    control: .init(text: item.control.text, bounds: item.control.bounds), action: item.action, after: stripped(item.after))
            })],
            properties: ["annotations": ["type": "array", "items": ["type": "object", "properties": pageFields,
                "required": Array(pageFields.keys), "additionalProperties": false]]])
        struct Pages: Decodable { let annotations: [CapabilityAnnotation] }
        let annotations = try JSONDecoder().decode(Pages.self, from: Data(pageCall.arguments.utf8)).annotations
        return (facts, annotations)
    }
}
