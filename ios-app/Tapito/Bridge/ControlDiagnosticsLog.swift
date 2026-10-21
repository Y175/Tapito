import Foundation
import OSLog

/// Bounded, process-local diagnostics. Callers record protocol metadata only:
/// only allowlisted coordinate geometry, never text arguments, received payloads, screenshots, goals, or secrets.
final class ControlDiagnosticsLog: @unchecked Sendable {
    static let revision = "control-diag-v1"
    private let lock = NSLock()
    private let capacity: Int
    private let console: Bool
    private let logger = Logger(subsystem: "com.y175.tapito", category: "DeviceControl")
    private let formatter: ISO8601DateFormatter
    private let started = ProcessInfo.processInfo.systemUptime
    private let header: String
    private var rows: [String] = []
    private var sequence = 0
    private var dropped = 0

    init(capacity: Int = 600, console: Bool = true) {
        self.capacity = max(1, capacity); self.console = console
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let bundle = Bundle.main
        func value(_ key: String) -> String { bundle.object(forInfoDictionaryKey: key) as? String ?? "unknown" }
        let purpose = value("NSLocalNetworkUsageDescription")
        #if targetEnvironment(simulator)
        let runtime = "simulator (local-network privacy cannot be validated here)"
        #else
        let runtime = "device"
        #endif
        header = """
        Tapito Control Diagnostics v1
        revision=\(Self.revision)
        imageExpiry=disabled modelImageIDParameter=false inputSceneGate=disabled inputImageMatch=disabled
        finishRequired=false
        bundle=\(bundle.bundleIdentifier ?? "unknown") version=\(value("CFBundleShortVersionString")) build=\(value("CFBundleVersion"))
        OS=\(ProcessInfo.processInfo.operatingSystemVersionString) runtime=\(runtime)
        SDK=\(value("DTSDKName")) XcodeBuild=\(value("DTXcodeBuild"))
        localNetworkUsageDescriptionPresent=\(!purpose.isEmpty && purpose != "unknown") (not permission status)
        Transport: authenticated local VPN. No command, screen, model payloads or secrets are recorded.
        """
    }
    func record(_ message: String, attempt: UUID? = nil) {
        let line = lock.withLock {
            sequence += 1
            let elapsed = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - started)
            let id = attempt.map { String($0.uuidString.prefix(8)) } ?? "app"
            // Prevent multiline/error text from impersonating another log event.
            let clean = String(message.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined().prefix(1600))
            let line = "\(formatter.string(from: Date())) +\(elapsed)s #\(sequence) [\(id)] \(clean)"
            rows.append(line)
            if rows.count > capacity { dropped += rows.count - capacity; rows.removeFirst(rows.count - capacity) }
            return line
        }
        if console { logger.notice("\(line, privacy: .public)") }
    }
    func report() -> String {
        lock.withLock {
            "\(header)\nexported=\(formatter.string(from: Date())) retained=\(rows.count) dropped=\(dropped)\n\n" + rows.joined(separator: "\n") + "\n"
        }
    }
}
