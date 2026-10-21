import Foundation

/// Captured pixels and geometry shared by local observation and input verification.
struct FrameImage: Sendable {
    let id: String
    // Retained property name for the original PNG route; NCM video emits JPEG.
    let png: Data
    var mimeType: String { png.starts(with: [0xff, 0xd8, 0xff]) ? "image/jpeg" : "image/png" }
    let width: Int
    let height: Int
    let capturedAt: Date
    let isDemo: Bool
    var capture: CaptureStamp? = nil
}
