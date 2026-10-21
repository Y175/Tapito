import Foundation

/// Per-run structural diagnostics survive app restarts and concurrent conversation controllers.
/// Callers supply tool names, stages, coordinate geometry and error fields, never text arguments or model text.
@MainActor final class AgentRunLog {
    private let file: URL
    private let formatter = ISO8601DateFormatter()
    init(runID: UUID) throws {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Tapito/AgentDiagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var rootURL = root, values = URLResourceValues(); values.isExcludedFromBackup = true
        try rootURL.setResourceValues(values)
        file = root.appendingPathComponent(runID.uuidString + ".log")
        try Data().write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let logs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "log" }
            .map { ($0, try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        for (old, _) in logs.dropFirst(30) where old != file { try FileManager.default.removeItem(at: old) }
    }
    func append(_ metadata: String) throws {
        let clean = metadata.components(separatedBy: .newlines).joined(separator: " ")
        let data = Data((formatter.string(from: Date()) + " " + clean + "\n").utf8)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
}
