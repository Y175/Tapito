import Foundation
import CryptoKit

/// Immutable validated text-only skills; no executable files or external resource paths.
public struct SkillPackage: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let summary: String
    public let version: String
    public let revision: String
    public let documents: [String: String]
    public var enabled: Bool
    public var resources: [String] { documents.keys.sorted() }
    /// Values are constructed from validated documents; revision hashes their exact bytes.
    public init(id: UUID, name: String, summary: String, version: String, revision: String, documents: [String: String], enabled: Bool) {
        self.id = id; self.name = name; self.summary = summary; self.version = version
        self.revision = revision; self.documents = documents; self.enabled = enabled
    }
    public static func validResource(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 240 && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":") &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") } &&
        ["md", "txt", "markdown"].contains((path as NSString).pathExtension.lowercased())
    }
    public static func make(documents: [String: String]) throws -> SkillPackage {
        guard !documents.isEmpty, documents.count <= 32, documents.keys.allSatisfy(validResource),
              documents.values.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 64 * 1_024 }),
              documents.values.reduce(0, { $0 + $1.utf8.count }) <= 512 * 1_024,
              let main = documents["SKILL.md"] else { throw AssistantError.invalid("技能包需要根目录 SKILL.md，只支持最多 32 个 UTF-8 Markdown/TXT 文档，单文件 64 KiB、整包 512 KiB") }
        let lines = main.components(separatedBy: .newlines)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { throw AssistantError.invalid("SKILL.md 需要 --- 元数据区，包含 name 和 description") }
        var metadata: [String: String] = [:], index = 1
        while index < end {
            let line = lines[index]; index += 1
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") { continue }
            guard !line.hasPrefix(" "), let colon = line.firstIndex(of: ":") else { throw AssistantError.invalid("技能元数据格式无效；支持简单文本字段或缩进的 | / > 多行文本") }
            let key = String(line[..<colon]), raw = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard metadata[key] == nil else { throw AssistantError.invalid("技能元数据字段重复") }
            var value = raw
            if ["|", ">", "|-", ">-"].contains(raw) {
                var parts: [String] = []
                while index < end && (lines[index].hasPrefix(" ") || lines[index].isEmpty) {
                    parts.append(lines[index].trimmingCharacters(in: .whitespaces)); index += 1
                }
                value = parts.joined(separator: raw.hasPrefix(">") ? " " : "\n")
            } else if value.count >= 2, (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
                value = String(value.dropFirst().dropLast())
            }
            metadata[key] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let name = metadata["name"], !name.isEmpty, name.count <= 80,
              let summary = metadata["description"], !summary.isEmpty, summary.count <= 1_000 else {
            throw AssistantError.invalid("技能 name 不能为空且最多 80 字，description 不能为空且最多 1000 字")
        }
        let version = metadata["version"] ?? "未标注"
        guard version.count <= 80 else { throw AssistantError.invalid("技能版本文本过长") }
        let canonical = documents.keys.sorted().map { "\($0.utf8.count):\($0)\(documents[$0]!.utf8.count):\(documents[$0]!)" }.joined()
        let revision = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return SkillPackage(id: UUID(), name: name, summary: summary, version: version, revision: revision, documents: documents, enabled: true)
    }
}
