import Foundation
import Testing
@testable import TapitoAgentCore

struct BuiltinSkillResourceTests {
    /// Exercise the same validated package/catalog used by load_skill, without a phone or provider.
    @Test func appReferencesArePackagedAndLoadInOneRequest() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tapito/BuiltinSkills")
        for name in ["weibo", "wechat", "ios-clock", "ios-notes"] {
            let folder = root.appendingPathComponent(name)
            let files = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
            var documents: [String: String] = [:]
            for case let url as URL in files where url.pathExtension == "md" {
                documents[String(url.path.dropFirst(folder.path.count + 1))] = try String(contentsOf: url, encoding: .utf8)
            }
            let package = try SkillPackage.make(documents: documents)
            let catalog = SkillCatalog(packages: [package])
            #expect(package.name == name)
            #expect(package.resources.contains { $0.hasPrefix("references/") })
            for resource in package.resources {
                let raw = try catalog.result(name: "load_skill", parameters: ["id": package.id.uuidString, "revision": package.revision, "resource": resource])
                let json = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
                #expect(json["content"] as? String == documents[resource])
                #expect(json["next_offset"] is NSNull)
            }
            // Follow every route listed in the entrypoint, excluding the generated optional learning reference.
            let entrypoint = try #require(documents["SKILL.md"])
            let regex = try NSRegularExpression(pattern: #"references/[a-z-]+\.md"#)
            for match in regex.matches(in: entrypoint, range: NSRange(entrypoint.startIndex..., in: entrypoint)) {
                let path = (entrypoint as NSString).substring(with: match.range)
                if path != "references/learned-operations.md" { #expect(documents[path] != nil) }
            }
        }
    }
}
