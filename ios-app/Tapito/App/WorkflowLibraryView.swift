import SwiftUI
import TapitoAgentCore

/// Presentation of portable core records; no device actions or learning decisions live in this view.
struct WorkflowLibraryView: View {
    let library: WorkflowLibrary
    @State private var flows: [LearnedWorkflow] = []
    @State private var jobs: [WorkflowLearningJob] = []
    @State private var error: String?
    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            Section("可执行操作流程") {
                if flows.isEmpty { Text("常用 App 任务执行后，有完整页面证据的步骤会生成候选。不会预置未经验证的坐标。") }
                ForEach(flows) { flow in
                    NavigationLink {
                        Form {
                            LabeledContent("名称", value: flow.trace.name)
                            LabeledContent("App", value: flow.trace.appBundleID)
                            LabeledContent("App 版本", value: flow.trace.appVersion)
                            LabeledContent("屏幕", value: "\(flow.trace.finalPage.width) × \(flow.trace.finalPage.height)")
                            LabeledContent("状态", value: state(flow.state))
                            LabeledContent("回放验证次数", value: String(flow.successfulReplays))
                            Text(flow.trace.systemVersion).font(.caption)
                            Text("输入内容每次由模型按你的任务填写。页面特征存于本机，比对通过后才发送操作；不会保存输入文本，不会自动重放失败步骤。动态结果仍需读取和核实。")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(flow.trace.steps.enumerated()), id: \.offset) { index, step in
                                VStack(alignment: .leading) {
                                    Text("\(index + 1). \(step.purpose)")
                                    Text(detail(step)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if let failure = flow.lastFailure { Text(failure).foregroundStyle(.red) }
                            if flow.state != "stale" {
                                Button(flow.state == "active" ? "停用此流程" : "审核并启用此版本") {
                                    perform {
                                        if flow.state == "active" { try await library.disable(id: flow.id) }
                                        else { try await library.activate(id: flow.id, revision: flow.revision) }
                                    }
                                }
                            }
                            if let error { Text(error).foregroundStyle(.red) }
                        }.navigationTitle("流程详情")
                    } label: {
                        VStack(alignment: .leading) {
                            Text(flow.trace.name)
                            Text("\(state(flow.state)) · \(flow.trace.steps.count) 步 · \(flow.trace.argumentKeys.count) 个输入参数").font(.caption)
                        }
                    }.swipeActions { Button("删除", role: .destructive) { perform { try await library.delete(id: flow.id) } } }
                }
            }
            Section("异步学习队列") {
                ForEach(jobs) { job in
                    VStack(alignment: .leading) {
                        Text(job.trace.name)
                        Text(job.state == "pending" ? "等待本机分析" : job.state == "compiled" ? "已生成候选" : "证据不足，未生成流程").font(.caption)
                        if let message = job.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Button("处理待学习记录") { perform { try await library.processPending() } }
                Button("清理已处理记录") { perform { try await library.clearProcessedJobs() } }
            }
        }.navigationTitle("操作流程与学习").task { await reload() }.refreshable { await reload() }
    }
    private func detail(_ step: WorkflowStep) -> String {
        switch step.action {
        case .tap(let x, let y): return "点击 (\(x), \(y)) · 页面及按钮区域比对"
        case .drag(let x, let y, let tx, let ty, let ms): return "拖动 (\(x), \(y)) → (\(tx), \(ty)) · \(ms) ms"
        case .insert(let key): return "直接输入参数 \(key) · 输入前页面比对"
        case .wait(let ms): return "等待 \(ms) ms"
        }
    }
    private func state(_ value: String) -> String {
        switch value {
        case "active": return "已启用"
        case "candidate": return "候选，待审核"
        case "stale": return "页面或版本已变化，待重新学习"
        default: return "已停用"
        }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await operation(); error = nil; await reload() }
            catch { self.error = error.localizedDescription }
        }
    }
    @MainActor private func reload() async {
        do { flows = try await library.workflows(); jobs = try await library.jobs() }
        catch { self.error = error.localizedDescription }
    }
}
