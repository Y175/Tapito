import Foundation

/// Measures elapsed execution time across suspension, independently of wall-clock changes or UI.
public struct ExecutionStopwatch: Sendable {
    /// Wall-clock start for presentation and correlation only.
    public let startedAt: Date
    /// Continuous clock includes waiting and device sleep; it is never persisted across launches.
    private let start: ContinuousClock.Instant
    /// Starts an independent interval at the execution boundary.
    public init() { startedAt = Date(); start = .now }
    /// Actual elapsed seconds, including network and approval waits inside this interval.
    public var seconds: TimeInterval {
        let parts = start.duration(to: .now).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
    /// Milliseconds for compact persistent diagnostics.
    public var milliseconds: Int { Int(seconds * 1_000) }
}
