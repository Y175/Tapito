import Foundation
import Testing
@testable import TapitoAgentCore

struct JevOCRTests {
    @Test @MainActor func flatProbabilityStillSelectsMaximum() throws {
        let data = Data("""
        {"model":"jev-1.14.0","answers":{"next_action":{"type":"choice","choice":"b","probabilities":{"a":0.499,"b":0.501},"confidence":0.002}},"usage":{"input_tokens":42,"output_tokens":3}}
        """.utf8)
        let selected = try JevDecisionClient.decode(data, options: [.init(id: "a", description: "A"), .init(id: "b", description: "B")])
        #expect(selected.optionID == "b")
        #expect(selected.confidence == 0.002)
    }

    @Test @MainActor func roundedOrPartialDistributionAndMismatchedChoiceStillUseMaximum() throws {
        let data = Data("""
        {"model":"jev","answers":{"next_action":{"type":"choice","choice":"b","probabilities":{"a":0.60,"b":0.39},"confidence":0.01}},"usage":{"input_tokens":42,"output_tokens":3}}
        """.utf8)
        let selected = try JevDecisionClient.decode(data, options: [
            .init(id: "a", description: "A"), .init(id: "b", description: "B"), .init(id: "c", description: "C")])
        #expect(selected.optionID == "a")
        #expect(selected.probability == 0.60)
        #expect(selected.responseDiagnostics?.contains("missing=1") == true)
        #expect(selected.responseDiagnostics?.contains("probability_sum=0.99") == true)
        #expect(selected.responseDiagnostics?.contains("choice_is_max=false") == true)
    }

    @Test @MainActor func nonWinningExtraKeyAndConfidenceMetadataDoNotBlockSelection() throws {
        let data = Data("""
        {"model":"jev","answers":{"next_action":{"type":"choice","choice":"a","probabilities":{"a":0.7,"outside":0.1},"confidence":1.001}},"usage":{"input_tokens":1,"output_tokens":1}}
        """.utf8)
        let selected = try JevDecisionClient.decode(data, options: [.init(id: "a", description: "A")])
        #expect(selected.optionID == "a")
        #expect(selected.confidence == 1.001)
        #expect(selected.responseDiagnostics?.contains("extra=1") == true)
    }

    @Test @MainActor func equalMaximaUseProviderChoiceThenRequestOrder() throws {
        for choice in ["a", "b", "outside"] {
            let data = Data("""
            {"model":"jev","answers":{"next_action":{"type":"choice","choice":"\(choice)","probabilities":{"a":0.4,"b":0.4},"confidence":0}},"usage":{"input_tokens":1,"output_tokens":1}}
            """.utf8)
            let selected = try JevDecisionClient.decode(data, options: [.init(id: "a", description: "A"), .init(id: "b", description: "B")])
            #expect(selected.optionID == (choice == "b" ? "b" : "a"))
        }
    }

    @Test @MainActor func unknownMaximumDoesNotSilentlyExecuteRunnerUp() throws {
        let data = Data("""
        {"model":"jev","answers":{"next_action":{"type":"choice","choice":"a","probabilities":{"a":0.3,"outside":0.7},"confidence":0}},"usage":{"input_tokens":1,"output_tokens":1}}
        """.utf8)
        #expect(throws: AssistantError.invalid("Jev 最高概率选项不属于本轮候选；没有发送设备操作。")) {
            try JevDecisionClient.decode(data, options: [.init(id: "a", description: "A")])
        }
    }

    @Test @MainActor func emptyProbabilitiesReportSpecificFailure() throws {
        let data = Data("""
        {"model":"jev","answers":{"next_action":{"type":"choice","choice":"a","probabilities":{},"confidence":0}},"usage":{"input_tokens":1,"output_tokens":1}}
        """.utf8)
        #expect(throws: AssistantError.invalid("Jev 没有可排序的概率结果；没有发送设备操作。")) {
            try JevDecisionClient.decode(data, options: [.init(id: "a", description: "A")])
        }
    }

    @Test @MainActor func malformedJSONReportsFailureWithoutEchoingPrivateResponse() throws {
        let data = Data("{private screen contents".utf8)
        #expect(throws: AssistantError.invalid("Jev 响应 JSON 字段无法解析；没有发送设备操作。")) {
            try JevDecisionClient.decode(data, options: [.init(id: "a", description: "A")])
        }
    }

}
