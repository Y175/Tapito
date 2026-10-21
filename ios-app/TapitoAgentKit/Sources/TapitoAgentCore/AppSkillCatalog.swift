import Foundation

/// Builds the per-run skill file view from immutable app skills and reviewed learning records.
/// JSON archives remain the source of truth; generated Markdown never changes executable coordinates.
public enum AppSkillCatalog {
    /// Maps bundled app guidance; this is not an execution allowlist. Other apps gain knowledge files after reviewed learning.
    public static let appNames = ["com.apple.mobilenotes": "ios-notes", "com.apple.mobiletimer": "ios-clock",
                                 "com.tencent.xin": "wechat", "com.sina.weibo": "weibo", "com.tencent.mqq": "qq"]

    /// Joins approved references into their app's skill without exposing images or task-specific inputs.
    public static func packages(base: [SkillPackage], pages: [PageCapability], workflows: [LearnedWorkflow],
                                additions: [LearnedSkill]) throws -> [SkillPackage] {
        var result = base.filter(\.enabled)
        guard Set(result.map(\.name)).count == result.count else { throw AssistantError.invalid("技能名称重复，无法按名称加载。") }
        for index in result.indices {
            let skill = result[index]
            let approved = additions.filter { $0.active && !$0.disabled && $0.baseSkillID == skill.id.uuidString && $0.baseRevision == skill.revision }
            if !approved.isEmpty {
                var documents = skill.documents
                documents["SKILL.md"]! += approved.map { "\n\n用户审核的补充，仅适用 App \($0.appBundleID)：\n\($0.instructions)" }.joined()
                result[index] = try replacing(skill, documents: documents)
            }
        }
        let activePages = pages.filter { $0.state == "active" }
        let activeFlows = workflows.filter { $0.state == "active" }
        let apps = Set(activePages.map { $0.evidence.appBundleID } + activeFlows.map { $0.trace.appBundleID })
        for app in apps.sorted() {
            let name = appNames[app] ?? "app-" + app
            let existing = result.firstIndex { $0.name == name }
            let skill: SkillPackage
            if let existing { skill = result[existing] }
            else {
                skill = try SkillPackage.make(documents: ["SKILL.md": "---\nname: \(name)\ndescription: 已审核的 \(app) 页面与操作经验\nversion: 1\n---\n按当前任务使用已审核经验，执行前加载 ios-operation。"])
            }
            var documents = skill.documents
            let resource = "references/learned-operations.md"
            guard documents[resource] == nil else { throw AssistantError.invalid("技能的学习引用路径被占用。") }
            let pageRows: [[String: Any]] = try activePages.filter { $0.evidence.appBundleID == app }.map { item in
                try item.validate()
                let e = item.evidence
                return ["id": item.id.uuidString, "revision": item.revision.uuidString, "page": item.pageName,
                        "function": item.function, "expected_result": item.observedResult,
                        "app_version": e.appVersion, "system_version": e.systemVersion,
                        "width": e.before.width, "height": e.before.height,
                        "control": e.control.text, "bounds": [e.control.bounds.x, e.control.bounds.y, e.control.bounds.width, e.control.bounds.height],
                        "before_labels": e.before.anchors.map(\.text), "after_labels": e.after.anchors.map(\.text),
                        "requires_text": e.action == .focusAndType,
                        "replay_allowed": !item.requiresFreshSemanticCheck]
            }
            let flowRows: [[String: Any]] = try activeFlows.filter { $0.trace.appBundleID == app }.map { item in
                try item.trace.validate()
                return ["id": item.id.uuidString, "revision": item.revision.uuidString, "name": item.trace.name,
                        "app_version": item.trace.appVersion, "system_version": item.trace.systemVersion,
                        "input_fields": item.trace.argumentKeys, "steps": item.trace.steps.map(\.purpose)]
            }
            let data = try JSONSerialization.data(withJSONObject: ["app_bundle_id": app, "pages": pageRows, "workflows": flowRows], options: [.sortedKeys, .prettyPrinted])
            documents[resource] = "# 已审核操作经验\n坐标仅供理解，不能跳过当前页面核验。replay_allowed=true 的页面可调用 run_page；完整流程可调用 run_workflow。动态身份、输入值和业务成功不能从历史推断。\n```json\n" + String(decoding: data, as: UTF8.self) + "\n```"
            documents["SKILL.md"]! += "\n\n## 学习到的页面和流程\n当前 App 有已审核经验，需要时加载 `\(resource)`。实际调用仍以当前工具定义及本轮用户目标为准。\n"
            let updated = try replacing(skill, documents: documents)
            if let existing { result[existing] = updated } else { result.append(updated) }
        }
        return result
    }

    private static func replacing(_ skill: SkillPackage, documents: [String: String]) throws -> SkillPackage {
        let checked = try SkillPackage.make(documents: documents)
        return SkillPackage(id: skill.id, name: checked.name, summary: checked.summary, version: checked.version,
                            revision: checked.revision, documents: checked.documents, enabled: true)
    }
}
