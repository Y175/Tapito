import SwiftUI
import TapitoAgentCore

/// Presentation only: all validation, revision checks and persistence live in TapitoAgentCore.
struct AssistantMemoryView: View {
    let workspace: AssistantWorkspace
    let workflows: WorkflowLibrary
    let knowledge: KnowledgeLibrary
    let skillRevisions: [String: String]
    @State private var memories: [AssistantMemory] = []
    @State private var episodes: [AssistantEpisode] = []
    @State private var learned: [LearnedSkill] = []
    @State private var automatic = true
    @State private var loaded = false
    @State private var error: String?
    @State private var editing: AssistantMemory?
    @State private var editor = false
    @State private var key = ""
    @State private var content = ""
    @State private var scope = "global"
    @State private var clear = false
    var body: some View {
        Form {
            Section {
                Toggle("允许对话写入记忆与学习候选", isOn: Binding(get: { automatic }, set: { value in perform { if !value { try await workflows.cancelPendingLearning() }; try await workspace.setAutomaticMemory(value) } }))
                    .disabled(!loaded)
                Text("仅保存明确表达的长期偏好和任务摘要。相关记忆会提供给所选模型；历史结果不代表当前结果，也不会授权新的操作。关闭后仍可读取和手动编辑已有记忆。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section("可执行流程") {
                NavigationLink("页面功能、控件与学习记录") { PageKnowledgeView(library: knowledge) }
                NavigationLink("流程、按钮位置与学习队列") { WorkflowLibraryView(library: workflows) }
                Text("学习在任务结束后异步处理。已审核流程会核对版本与页面，在本机连续执行；页面变化会停止并等待纠正。").font(.caption).foregroundStyle(.secondary)
            }
            Section("个人记忆") {
                ForEach(memories) { item in
                    Button {
                        editing = item; key = item.key; content = item.content; scope = item.scope; editor = true
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.key).foregroundStyle(.primary)
                            Text(item.content).foregroundStyle(.secondary)
                            Text(item.scope).font(.caption).foregroundStyle(.secondary)
                        }
                    }.swipeActions { Button("删除", role: .destructive) { perform { try await workspace.forget(id: item.id, expectedRevision: item.revision) } } }
                }
                Button("添加记忆") { editing = nil; key = ""; content = ""; scope = "global"; editor = true }.disabled(!loaded)
            }
            Section("过去任务摘要") {
                ForEach(episodes) { item in
                    NavigationLink(item.task) {
                        Form {
                            Text(item.summary)
                            Text("这是历史对话摘要，不证明设备操作成功，也不会自动重放动作。").font(.caption)
                            Text(item.date, style: .date)
                        }.navigationTitle("任务摘要")
                    }.swipeActions { Button("删除", role: .destructive) { perform { try await workspace.forgetEpisode(id: item.id) } } }
                }
            }
            Section("技能学习") {
                if learned.isEmpty { Text("暂无文字技能修订。新任务学到的页面与控件，请在“页面功能、控件与学习记录”中查看。") }
                ForEach(learned) { item in
                    NavigationLink {
                        Form {
                            LabeledContent("适用 App", value: item.appBundleID)
                            LabeledContent("观察任务数", value: String(item.verifiedRuns.count))
                            Text(item.instructions)
                            ForEach(item.observations, id: \.runID) { evidence in
                                Text("观察文字：\(evidence.text)\n任务：\(evidence.runID)\n帧：\(evidence.frameID)").font(.caption)
                            }
                            if skillRevisions[item.baseSkillID] != item.baseRevision {
                                Text("基础技能已更新或停用，此修订不参与新任务。请重新验证。").foregroundStyle(.orange)
                            }
                            Text("这是基于屏幕文字观察的候选，尚不证明整条流程正确。启用前检查前置条件和结果验证方式；禁止把旧坐标或历史授权当成当前授权。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button(item.active ? "停用此修订" : "审核并启用此修订") {
                                perform {
                                    if item.active { try await workspace.disableSkill(id: item.id) }
                                    else {
                                        guard let revision = skillRevisions[item.baseSkillID] else { throw AssistantError.invalid("基础技能不可用。") }
                                        try await workspace.activateSkill(id: item.id, expectedRevision: item.revision, currentBaseRevision: revision)
                                    }
                                }
                            }
                            if let error { Text(error).foregroundStyle(.red) }
                        }.navigationTitle("技能修订")
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.appBundleID)
                            Text(skillRevisions[item.baseSkillID] != item.baseRevision ? "基础技能版本不匹配" : item.active ? "已启用 · 下一任务生效" : item.disabled ? "已停用" : "候选 · 待审核").font(.caption)
                        }
                    }.swipeActions { Button("删除", role: .destructive) { perform { try await workspace.forgetSkill(id: item.id) } } }
                }
            }
            Section {
                Button("清空记忆、任务摘要与学习记录", role: .destructive) { clear = true }.disabled(!loaded)
            }
        }
        .navigationTitle("记忆与学习")
        .task { await reload() }
        .refreshable { await reload() }
        .confirmationDialog("清空后无法恢复，旧任务也不能重新写回这些内容。", isPresented: $clear, titleVisibility: .visible) {
            Button("清空全部助手记忆", role: .destructive) { perform { try await knowledge.clear(); try await workflows.clear(); try await workspace.clear() } }
        }
        .sheet(isPresented: $editor) {
            NavigationStack {
                Form {
                    TextField("标题", text: $key)
                    TextField("内容", text: $content, axis: .vertical)
                    TextField("范围：global 或 App 标识", text: $scope)
                    if let editing { Text("来源：" + editing.evidence).font(.caption) }
                    if let error { Text(error).foregroundStyle(.red) }
                }.navigationTitle(editing == nil ? "添加记忆" : "编辑记忆")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { editor = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                perform {
                                    try await workspace.edit(id: editing?.id, key: key, content: content, scope: scope, expectedRevision: editing?.revision)
                                    editor = false
                                }
                            }
                        }
                    }
            }
        }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await operation(); error = nil; await reload() }
            catch { self.error = error.localizedDescription }
        }
    }
    @MainActor private func reload() async {
        do {
            memories = try await workspace.memories(); episodes = try await workspace.episodes(); learned = try await workspace.learnedSkills()
            automatic = try await workspace.automaticMemoryEnabled(); loaded = true
        } catch { self.error = error.localizedDescription; loaded = false }
    }
}
