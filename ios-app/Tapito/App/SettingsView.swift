import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AgentSessionController
    @Environment(\.dismiss) private var dismiss
    @StateObject private var location = BackgroundLocationAccess.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var clear = false
    @State private var clearAssets = false
    @State private var assetStatus = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("模型") {
                    NavigationLink { ProvidersView(model: model) } label: {
                        Text("供应商")
                    }.accessibilityIdentifier("openProviders")
                }
                Section("手机操控") {
                    NavigationLink { DeviceConnectionSettingsView() } label: {
                        Text("连接与验证")
                    }.accessibilityIdentifier("deviceConnectionSettings")
                }
                Section {
                    LabeledContent("执行方式", value: "任务期间后台定位")
                    Text(location.status).accessibilityIdentifier("backgroundLocationStatus")
                    if location.authorization == .notDetermined || location.authorization == .authorizedWhenInUse {
                        Button("授权后台定位") { location.requestAuthorization() }
                            .accessibilityIdentifier("authorizeBackgroundLocation")
                    }
                    Button("打开系统权限设置") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                } header: {
                    Text("后台执行")
                } footer: {
                    Text("请将定位设为“始终”允许，可关闭精确位置。仅执行任务时启用定位，不保存或上传坐标；任务结束、停止或锁屏后释放。执行期间不占用麦克风或音频。")
                }
                Section("扩展能力") {
                    NavigationLink("记忆与学习") { AssistantMemoryView(workspace: model.workspace, workflows: model.workflows, knowledge: model.knowledge, skillRevisions: Dictionary(uniqueKeysWithValues: model.skills.enabledSnapshot.map { ($0.id.uuidString, $0.revision) })) }
                    NavigationLink { SkillsView(model: model, store: model.skills) } label: {
                        Text("技能")
                    }.accessibilityIdentifier("manageSkills")
                }
                Section("本地记录") {
                    Button("清空本地会话与任务记录", role: .destructive) { clear = true }
                        .disabled(model.hasBusySessions)
                    Button("清理未引用附件", role: .destructive) { clearAssets = true }
                        .disabled(model.hasBusySessions).accessibilityIdentifier("clearUnusedAttachments")
                    if !assetStatus.isEmpty { Text(assetStatus).font(.caption) }
                }
                if let warning = model.storageWarning { Text(warning).foregroundStyle(.orange) }
            }
            .onAppear { location.refresh() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { location.refresh() } }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .confirmationDialog("删除本机保存的任务和结果？无法在 App 内恢复。", isPresented: $clear, titleVisibility: .visible) {
                Button("清空记录", role: .destructive) { model.clearHistory() }
            }
            .alert("清理未引用附件？", isPresented: $clearAssets) {
                Button("取消", role: .cancel) {}
                Button("清理", role: .destructive) {
                    Task {
                        do { assetStatus = "已清理 \(try await model.clearUnreferencedAttachments()) 个未引用文件" }
                        catch { assetStatus = "未能清理附件；原文件保留" }
                    }
                }
            } message: { Text("现有消息与草稿引用的原图和文件会保留。未引用文件删除后无法恢复。") }
        }
    }
}
