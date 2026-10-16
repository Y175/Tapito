import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import TapitoAgentCore

/// Platform-only pixel sampling. The core stores portable samples and never depends on UIKit/Vision.
enum WorkflowPixels {
    static func page(_ frame: FrameImage) throws -> WorkflowPage {
        let image = try decode(frame)
        // Ignore clock/island and the home indicator; retain the rest, including overlays and keyboard.
        let crop = CGRect(x: 0, y: Double(frame.height) * 0.065,
                          width: Double(frame.width), height: Double(frame.height) * 0.91).integral
        guard let clipped = image.cropping(to: crop) else { throw AppError.invalid("流程页面裁剪失败") }
        return WorkflowPage(width: frame.width, height: frame.height, pixels: try sample(clipped, width: 24, height: 48))
    }
    static func target(_ frame: FrameImage, x: Int, y: Int) throws -> Data {
        let image = try decode(frame)
        guard x >= 0, x < frame.width, y >= 0, y < frame.height else { throw AppError.invalid("流程按钮坐标越界") }
        let size = min(96, min(frame.width, frame.height))
        let rect = CGRect(x: max(0, min(frame.width - size, x - size / 2)),
                          y: max(0, min(frame.height - size, y - size / 2)), width: size, height: size)
        guard let clipped = image.cropping(to: rect) else { throw AppError.invalid("流程按钮区域裁剪失败") }
        return try sample(clipped, width: 16, height: 16)
    }
    /// Only exact OCR label rectangles are retained; neighboring messages and result text are excluded.
    static func interfacePatches(_ frame: FrameImage, bounds: [InterfaceBounds]) throws -> [Data] {
        let image = try decode(frame)
        return try bounds.map { box in
            try box.validate(width: frame.width, height: frame.height)
            guard let clipped = image.cropping(to: CGRect(x: box.x, y: box.y, width: box.width, height: box.height)) else {
                throw AppError.invalid("页面 UI 文字区域裁剪失败")
            }
            return try sample(clipped, width: 16, height: 16)
        }
    }
    /// An icon/visual target has no OCR label. Persist its digest, never neighboring content pixels.
    static func visualDigest(_ frame: FrameImage, bounds: InterfaceBounds) throws -> String {
        let samples = try interfacePatches(frame, bounds: [bounds])
        guard let sample = samples.first else { throw AppError.invalid("视觉控件区域为空") }
        return SHA256.hash(data: sample).map { String(format: "%02x", $0) }.joined()
    }
    static func targetMatches(_ expected: Data, _ actual: Data) throws -> Bool {
        guard expected.count == 768, actual.count == 768 else { throw AppError.invalid("流程按钮特征无效") }
        let diff = zip(expected, actual).map { abs(Int($0) - Int($1)) }
        return diff.max()! <= 28 && diff.reduce(0, +) <= diff.count * 3
    }
    private static func decode(_ frame: FrameImage) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(frame.png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width == frame.width, image.height == frame.height else {
            throw AppError.invalid("流程画面解码失败或像素尺寸不匹配")
        }
        return image
    }
    private static func sample(_ image: CGImage, width: Int, height: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = bytes.withUnsafeMutableBytes { pointer -> Bool in
            guard let context = CGContext(data: pointer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
        }
        guard rendered else { throw AppError.invalid("流程页面特征计算失败") }
        return Data(bytes.enumerated().compactMap { $0.offset % 4 == 3 ? nil : $0.element })
    }
}
