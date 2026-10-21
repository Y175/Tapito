import Foundation

/// Metadata of the image supplied to a device tool, independent of its transport.
struct CaptureStamp: Sendable, Equatable {
    let sequence: UInt64
    let uptime: TimeInterval
    let presentationSeconds: Double
    let width: Int
    let height: Int
    let videoOrientation: UInt32
}
