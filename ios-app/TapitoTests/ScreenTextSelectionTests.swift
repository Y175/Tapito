import XCTest
#if !TAPITO_OCR_SELECTION_HOST_TESTS
@testable import Tapito
#endif

/// Exercises the production OCR selection contract without Vision, a model or device input.
final class ScreenTextSelectionTests: XCTestCase {
    private func candidate(_ id: String, x: Int = 20, y: Int = 20,
                           confidence: Float = 0.97, text: String = "搜索") -> ScreenTextCandidate {
        .init(id: id, text: text, confidence: confidence, bounds: .init(x: x, y: y, width: 60, height: 30))
    }
    private func observation(_ candidates: [ScreenTextCandidate]) -> ScreenTextObservation {
        .init(frameID: "frame", width: 600, height: 800, candidates: candidates, elapsedMS: 1)
    }

    func testJevDirectSelectionUsesLowConfidenceDuplicateCandidateWithoutHeuristics() throws {
        let screen = observation([candidate("a", confidence: 0.1), candidate("b", y: 500, confidence: 0.2)])
        XCTAssertEqual(try screen.target(id: "b", directSelection: true).id, "b")
        XCTAssertThrowsError(try screen.target(id: "missing", directSelection: true))
        XCTAssertThrowsError(try screen.target(id: "b"))
    }

    func testSeparatedSameLabelControlsCanBeSelectedByPosition() throws {
        let screen = observation([candidate("top"), candidate("bottom", y: 500)])
        XCTAssertEqual(screen.positions(for: screen.candidates[0]), ["topmost"])
        XCTAssertEqual(screen.positions(for: screen.candidates[1]), ["bottommost"])
        XCTAssertEqual(try screen.target(id: "top", position: "topmost").id, "top")
        XCTAssertEqual(try screen.target(id: "bottom", position: "bottommost").id, "bottom")
        XCTAssertThrowsError(try screen.target(id: "bottom", position: "topmost"))
        XCTAssertThrowsError(try screen.target(id: "top"))

        let horizontal = observation([candidate("left"), candidate("right", x: 400)])
        XCTAssertEqual(try horizontal.target(id: "left", position: "leftmost").id, "left")
        XCTAssertEqual(try horizontal.target(id: "right", position: "rightmost").id, "right")
    }

    func testOverlapsTiesLowConfidenceAndInventedIDsStillRequireCorrection() throws {
        for peers in [[candidate("a"), candidate("b")], [candidate("a"), candidate("b", x: 30, y: 30)]] {
            let screen = observation(peers)
            XCTAssertTrue(screen.positions(for: peers[0]).isEmpty)
            for position in ScreenTextObservation.Position.allCases {
                XCTAssertThrowsError(try screen.target(id: "a", position: position.rawValue))
            }
        }
        let screen = observation([candidate("a", confidence: 0.4), candidate("b", y: 500)])
        XCTAssertThrowsError(try screen.target(id: "a", position: "topmost"))
        XCTAssertThrowsError(try screen.target(id: "invented", position: "topmost"))
        XCTAssertThrowsError(try screen.target(id: "b", position: "guess"))
    }

    func testReceiptIncludesPositionsAndDoesNotRequireAnImageForDuplicateText() throws {
        let screen = observation([candidate("a"), candidate("b", y: 500)])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try screen.page(offset: 0).utf8)) as? [String: Any])
        XCTAssertEqual(payload["image_uploaded"] as? Bool, false)
        let rows = try XCTUnwrap(payload["candidates"] as? [[String: Any]])
        XCTAssertEqual(rows[0]["positions"] as? [String], ["topmost"])
        XCTAssertEqual(rows[1]["positions"] as? [String], ["bottommost"])
        XCTAssertEqual(rows[0]["text_target"] as? String, "duplicate")
        let unique = observation([candidate("only")])
        XCTAssertEqual(try unique.target(id: "only").id, "only")
    }

    func testPositionsConsiderSameLabelOutsideTheCurrentReceiptPage() throws {
        let fillers = (0..<100).map { candidate("f\($0)", text: String(repeating: "内容", count: 20) + String($0)) }
        let screen = observation([candidate("top")] + fillers + [candidate("bottom", y: 500)])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try screen.page(offset: 0).utf8)) as? [String: Any])
        let rows = try XCTUnwrap(payload["candidates"] as? [[String: Any]])
        XCTAssertNotNil(payload["next_offset"] as? Int)
        XCTAssertFalse(rows.contains { $0["id"] as? String == "bottom" })
        XCTAssertEqual(rows[0]["positions"] as? [String], ["topmost"])
        XCTAssertThrowsError(try screen.target(id: "top", position: "bottommost"))
    }
}
