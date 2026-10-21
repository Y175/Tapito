import XCTest
import CoreGraphics
import ImageIO
#if !TAPITO_OCR_SELECTION_HOST_TESTS
@testable import Tapito
#endif

/// Synthetic pixels exercise the production comparison and boundary logic without operating a phone.
final class ScreenStabilityTests: XCTestCase {
    private func frame(y: Int = 220, width: Int = 600, color: CGFloat = 0,
                       unrelatedAnimation: Bool = false) throws -> FrameImage {
        let height = 900
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: color, alpha: 1))
        context.fill(CGRect(x: 240, y: height - y - 40, width: 120, height: 40))
        if unrelatedAnimation {
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 30, width: 600, height: 180))
        }
        let image = try XCTUnwrap(context.makeImage()), data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return .init(id: UUID().uuidString, png: data as Data, width: width, height: height, capturedAt: Date(), isDemo: true)
    }

    func testMovingTargetAndDimensionChangeRejectOldCoordinates() throws {
        let before = try frame(y: 442), after = try frame(y: 220)
        let region = try ScreenStability.targetRegion(x: 300, y: 462, bounds: nil, frame: before)
        XCTAssertFalse(try ScreenStability.compare(before, after, region: region).matches)
        XCTAssertFalse(try ScreenStability.compare(before, after).matches)
        XCTAssertFalse(try ScreenStability.compare(before, frame(width: 601), region: region).matches)
    }

    func testStableTargetToleratesTinyPixelNoiseButNotChangesAtTarget() throws {
        let before = try frame(), region = try ScreenStability.targetRegion(x: 300, y: 240, bounds: nil, frame: before)
        XCTAssertTrue(try ScreenStability.compare(before, frame(color: 0.005), region: region).matches)
        XCTAssertTrue(try ScreenStability.compare(before, frame(unrelatedAnimation: true), region: region).matches)
        XCTAssertFalse(try ScreenStability.compare(before, frame(color: 1), region: region).matches)
    }

    func testSettlingUsesNewFrameAfterLayoutMovement() async throws {
        let old = try frame(y: 442), ready = try frame()
        var captures = 0
        let result = try await ScreenStability.captureSettled {
            captures += 1
            return captures == 1 ? old : ready
        }
        XCTAssertTrue(result.stable); XCTAssertEqual(result.samples, 3)
        XCTAssertEqual(result.frame.id, ready.id)
    }

    func testContinuousChangesAreBoundedAndReportedAsChanging() async throws {
        let a = try frame(y: 442), b = try frame()
        var captures = 0
        let result = try await ScreenStability.captureSettled {
            captures += 1; return captures % 2 == 1 ? a : b
        }
        XCTAssertFalse(result.stable); XCTAssertEqual(captures, 4)
    }

    func testCaptureFailureAndCancellationNeverBecomeStableResults() async throws {
        do {
            _ = try await ScreenStability.captureSettled { throw AppError.unavailable("capture failed") }
            XCTFail("Capture failure must propagate")
        } catch { XCTAssertEqual(error as? AppError, .unavailable("capture failed")) }
        let ready = try frame()
        let task = Task { try await ScreenStability.captureSettled { ready } }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must propagate") } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testTinyNormalizedDriftIsCorrectedButRealOutOfBoundsIsExcluded() throws {
        let tiny = ScreenTextCandidate.PixelBounds.checked(CGRect(x: -0.0000001, y: 0.5, width: 0.2, height: 0.5000001), width: 1206, height: 2624)
        XCTAssertTrue(tiny.adjusted); XCTAssertEqual(tiny.bounds?.x, 0); XCTAssertEqual(tiny.bounds?.y, 0)
        for box in [CGRect(x: -0.01, y: 0, width: 0.2, height: 0.2),
                    CGRect(x: 0.9, y: 0, width: 0.2, height: 0.2),
                    CGRect(x: 0, y: 0, width: -0.2, height: 0.2),
                    CGRect(x: CGFloat.nan, y: 0, width: 0.2, height: 0.2)] {
            XCTAssertNil(ScreenTextCandidate.PixelBounds.checked(box, width: 1206, height: 2624).bounds)
        }
    }

    func testExcludedGeometryIsExplicitEvenWhenNoUsableTextRemains() throws {
        let observation = ScreenTextObservation(frameID: "partial", width: 1206, height: 2624, candidates: [],
                                               elapsedMS: 2, excludedCandidates: 1, adjustedCandidates: 0)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(observation.page(offset: 0).utf8)) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "partial")
        XCTAssertEqual(object["excluded_candidates"] as? Int, 1)
        XCTAssertEqual(object["image_uploaded"] as? Bool, false)
        XCTAssertThrowsError(try observation.target(id: "text-1"))
    }
}
