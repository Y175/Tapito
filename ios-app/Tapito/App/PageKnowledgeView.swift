import SwiftUI
import TapitoAgentCore

/// Review only; page recognition, tool execution and learning policy remain in the core package.
struct PageKnowledgeView: View {
    let library: KnowledgeLibrary
    @State private var capabilities: [PageCapability] = []
    @State private var jobs: [AssistantLearningJob] = []
    @State private var error: String?
    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            Section("页面与功能") {
                Text("保存稳定 UI 文字、控件位置与前后页面；不保存消息、联系人或榜单正文。候选须核对后启用。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(capabilities) { item in
                    NavigationLink {
                        Form {
                            LabeledContent("页面", value: item.pageName)
                            LabeledContent("功能", value: item.function)
                            LabeledContent("App", value: item.evidence.appBundleID)
                            LabeledContent("版本", value: item.evidence.appVersion)
                            LabeledContent("状态", value: item.state)
                            LabeledContent("控件", value: item.evidence.control.text)
                            LabeledContent("位置", value: "\(item.evidence.control.bounds.centerX), \(item.evidence.control.bounds.centerY)")
                            LabeledContent("操作", value: item.evidence.action == .focusAndType ? "聚焦并输入任务参数" : "点击")
                            Text("观察结果：" + item.observedResult)
                            if item.requiresFreshSemanticCheck {
                                Text("此功能需要核对本次内容或目标，执行时仍经过模型观察。").font(.caption)
                            }
                            Text("此结果证明页面变化，不自动证明消息已发送或记录已创建。").font(.caption).foregroundStyle(.secondary)
                            Section("页面基础 OCR 元素") {
                                ForEach(Array(item.evidence.before.anchors.enumerated()), id: \.offset) { _, anchor in
                                    LabeledContent(anchor.text, value: "\(anchor.bounds.x), \(anchor.bounds.y)")
                                }
                            }
                            Section("操作后的页面元素") {
                                ForEach(Array(item.evidence.after.anchors.enumerated()), id: \.offset) { _, anchor in
                                    LabeledContent(anchor.text, value: "\(anchor.bounds.x), \(anchor.bounds.y)")
                                }
                            }
                            Button(item.state == "active" ? "停用" : "审核并启用") {
                                perform {
                                    if item.state == "active" { try await library.disable(id: item.id) }
                                    else { try await library.activate(id: item.id, revision: item.revision) }
                                }
                            }
                            .disabled(item.state == "stale")
                            if item.state == "stale" { Text("此版本已失效；完成纠错任务后审核新的候选。").font(.caption) }
                            if let error { Text(error).foregroundStyle(.red) }
                        }.navigationTitle("页面能力")
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.pageName + " · " + item.function)
                            Text(item.state + " · " + item.evidence.control.text).font(.caption).foregroundStyle(.secondary)
                        }
                    }.swipeActions { Button("删除", role: .destructive) { perform { try await library.delete(id: item.id) } } }
                }
            }
            Section("异步记忆与技能学习") {
                ForEach(jobs) { job in
                    VStack(alignment: .leading) {
                        Text(job.state)
                        Text("\(job.transitions.count) 段页面操作证据").font(.caption)
                        if let message = job.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Button("清理已处理记录") { perform { try await library.clearProcessed() } }
            }
        }.navigationTitle("页面知识").task { await reload() }.refreshable { await reload() }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await operation(); error = nil; await reload() }
            catch { self.error = error.localizedDescription }
        }
    }
    @MainActor private func reload() async {
        do { capabilities = try await library.capabilities(); jobs = try await library.jobs() }
        catch { self.error = error.localizedDescription }
    }
}
