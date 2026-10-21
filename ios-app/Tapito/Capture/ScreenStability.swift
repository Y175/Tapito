import Foundation
import CoreGraphics
import ImageIO

/// Local pixel comparison for settling observations and rejecting obsolete click targets.
/// These transient samples are neither model input nor learned button coordinates.
enum ScreenStability {
    struct SettledFrame {
        let frame: FrameImage
        let stable: Bool
        let samples: Int
    }

    /// Read-only polling is bounded; a changing video still yields an explicitly changing observation.
    static func captureSettled(capture: () async throws -> FrameImage) async throws -> SettledFrame {
        try Task.checkCancellation()
        var previous = try await capture()
        for sample in 2...4 {
            try await Task.sleep(for: .milliseconds(160))
            let current = try await capture()
            try Task.checkCancellation()
            if try compare(previous, current).matches { return .init(frame: current, stable: true, samples: sample) }
            previous = current
        }
        return .init(frame: previous, stable: false, samples: 4)
    }

    struct Comparison {
        let meanDifference: Double
        let changedFraction: Double
        /// Small JPEG noise is tolerated; visible changes require a new decision.
        var matches: Bool { meanDifference <= 3 && changedFraction <= 0.01 }
    }

    static func compare(_ before: FrameImage, _ after: FrameImage, region: CGRect? = nil) throws -> Comparison {
        guard before.width == after.width, before.height == after.height else {
            return .init(meanDifference: 255, changedFraction: 1)
        }
        // Exclude system clock/island and home indicator from whole-page settling.
        // A target comparison never masks the target, even if it is near an overlay.
        let box = region ?? CGRect(x: 0, y: Double(before.height) * 0.065,
                                    width: Double(before.width), height: Double(before.height) * 0.91)
        let size = region == nil ? (64, 128) : (64, 64)
        let a = try sample(before, region: box, width: size.0, height: size.1)
        let b = try sample(after, region: box, width: size.0, height: size.1)
        var total = 0, changed = 0
        for (x, y) in zip(a, b) {
            let difference = abs(Int(x) - Int(y))
            total += difference
            if difference > 24 { changed += 1 }
        }
        return .init(meanDifference: Double(total) / Double(a.count), changedFraction: Double(changed) / Double(a.count))
    }

    /// Compare the observed label plus padding, or a visual target and its immediate surroundings.
    static func targetRegion(x: Int, y: Int, bounds: ScreenTextCandidate.PixelBounds?, frame: FrameImage) throws -> CGRect {
        guard x >= 0, x < frame.width, y >= 0, y < frame.height else { throw AppError.invalid("点击坐标超出画面") }
        let rect = bounds.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).insetBy(dx: -16, dy: -16) }
            ?? CGRect(x: x - 72, y: y - 72, width: 144, height: 144)
        return rect.intersection(CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
    }

    private static func sample(_ frame: FrameImage, region: CGRect, width: Int, height: Int) throws -> [UInt8] {
        guard let source = CGImageSourceCreateWithData(frame.png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == frame.width, image.height == frame.height,
              !region.isEmpty, let crop = image.cropping(to: region.integral) else {
            throw AppError.protocolViolation("画面复核无法解码截图或区域无效")
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw AppError.unavailable("画面复核无法生成本机像素样本") }
        return bytes.enumerated().compactMap { $0.offset % 4 == 3 ? nil : $0.element }
    }
}
