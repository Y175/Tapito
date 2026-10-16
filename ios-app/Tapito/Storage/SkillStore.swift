import Foundation
import Combine
import CryptoKit
import TapitoAgentCore

@MainActor final class SkillStore: ObservableObject {
    @Published private(set) var packages: [SkillPackage] = []
    @Published private(set) var warning: String?
    private let file: URL?
    private var writable = true
    /// Shipped documents and references are immutable, outside the imported archive.
    private var shippedPackages: [SkillPackage] = []
    private struct Archive: Codable { var version = 1; let packages: [SkillPackage] }
    init(directory: URL? = nil, inMemory: Bool = false) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tapito/Skills")
        file = inMemory ? nil : root.appendingPathComponent("skills-v1.json")
        do {
            guard let root = Bundle.main.url(forResource: "BuiltinSkills", withExtension: nil) else {
                throw AppError.unavailable("缺少内置技能资源目录")
            }
            let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
                .sorted { ($0.lastPathComponent == "ios-operation" ? "0" : $0.lastPathComponent) < ($1.lastPathComponent == "ios-operation" ? "0" : $1.lastPathComponent) }
            let loaded = try folders.map { folder -> SkillPackage in
                guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw AppError.invalid("内置技能目录含意外文件") }
                let checked = try SkillPackage.make(documents: Self.readDocuments(folder))
                let digest = Array(SHA256.hash(data: Data(("Tapito.skill." + folder.lastPathComponent).utf8)).prefix(16))
                let id = folder.lastPathComponent == "ios-operation" ? Self.builtinID : UUID(uuid: (digest[0],digest[1],digest[2],digest[3],digest[4],digest[5],digest[6],digest[7],digest[8],digest[9],digest[10],digest[11],digest[12],digest[13],digest[14],digest[15]))
                return SkillPackage(id: id, name: checked.name, summary: checked.summary, version: checked.version,
                    revision: checked.revision, documents: checked.documents, enabled: true)
            }
            guard loaded.contains(where: { $0.id == Self.builtinID }) else { throw AppError.unavailable("缺少基础 iOS 技能") }
            shippedPackages = loaded
        } catch { warning = "内置技能加载失败：\(error.localizedDescription)" }
        if inMemory { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            var url = root, values = URLResourceValues(); values.isExcludedFromBackup = true; try url.setResourceValues(values)
            if let file, FileManager.default.fileExists(atPath: file.path) {
                let info = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                guard info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 16 * 1_024 * 1_024 else { throw AppError.invalid("技能存档无效") }
                let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
                guard archive.version == 1, Set(archive.packages.map(\.id)).count == archive.packages.count else { throw AppError.invalid("技能存档版本不支持") }
                for package in archive.packages {
                    let checked = try SkillPackage.make(documents: package.documents)
                    guard checked.revision == package.revision, checked.name == package.name, checked.summary == package.summary, checked.version == package.version else { throw AppError.invalid("技能内容校验失败") }
                }
                packages = archive.packages
            }
        } catch { writable = false; warning = "技能未能读取；已保留原存档，暂不能修改" }
    }
    // Shipped references are immutable and never written into user archives.
    static let builtinID = UUID(uuidString: "8098422E-79C6-49BF-9205-E58F166F42D5")!
    var builtinPackages: [SkillPackage] { shippedPackages }
    var enabledSnapshot: [SkillPackage] { builtinPackages + packages.filter(\.enabled) }
    @discardableResult func add(documents: [String: String]) throws -> SkillPackage {
        try Task.checkCancellation()
        let candidate = try SkillPackage.make(documents: documents)
        if let existing = packages.first(where: { $0.revision == candidate.revision }) { return existing }
        try save(packages + [candidate]); return candidate
    }
    @discardableResult func importPackage(_ url: URL) throws -> SkillPackage {
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try add(documents: Self.readDocuments(url))
    }
    /// Shared strict text-package validation applies equally to shipped and imported skills.
    private static func readDocuments(_ url: URL) throws -> [String: String] {
        let rootInfo = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootInfo.isSymbolicLink != true else { throw AppError.invalid("不支持符号链接技能包") }
        var documents: [String: String] = [:]
        func read(_ file: URL, resource: String) throws {
            try Task.checkCancellation()
            guard SkillPackage.validResource(resource), documents.count < 32 else { throw AppError.invalid("技能包只允许 Markdown/TXT 文档，不包含脚本、图片或压缩包") }
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 64 * 1_024,
                  let text = String(data: try Data(contentsOf: file), encoding: .utf8) else { throw AppError.invalid("技能文档不是有效 UTF-8 普通文件或超过 64 KiB") }
            documents[resource] = text
        }
        if rootInfo.isDirectory == true {
            let root = url.standardizedFileURL.path + "/"
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { throw AppError.invalid("无法读取技能文件夹") }
            var visited = 0
            for case let file as URL in enumerator {
                try Task.checkCancellation(); visited += 1
                guard visited <= 128 else { throw AppError.invalid("技能包目录过多；请选择只含技能文本的文件夹") }
                let info = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard info.isSymbolicLink != true, file.standardizedFileURL.path.hasPrefix(root) else { throw AppError.invalid("技能包包含非法路径或符号链接") }
                if info.isDirectory == true { continue }
                try read(file, resource: String(file.standardizedFileURL.path.dropFirst(root.count)))
            }
        } else {
            guard url.lastPathComponent == "SKILL.md" else { throw AppError.invalid("请选择 SKILL.md 或包含它的文本技能文件夹") }
            try read(url, resource: "SKILL.md")
        }
        return documents
    }
    func setEnabled(_ enabled: Bool, id: UUID) throws {
        var next = packages
        guard let index = next.firstIndex(where: { $0.id == id }) else { throw AppError.invalid("技能不存在") }
        next[index].enabled = enabled; try save(next)
    }
    func remove(_ id: UUID) throws {
        guard id != Self.builtinID else { throw AppError.invalid("内置技能不能删除") }
        try save(packages.filter { $0.id != id })
    }
    private func save(_ next: [SkillPackage]) throws {
        guard writable else { throw AppError.unavailable(warning ?? "技能不可写") }
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(Archive(packages: next))
        guard data.count <= 16 * 1_024 * 1_024 else { throw AppError.invalid("技能存储已满，请先确认删除不需要的版本") }
        if let file { try data.write(to: file, options: [.atomic, .completeFileProtection]) }
        packages = next
    }
}
