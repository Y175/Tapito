import Foundation

/// Persisted analysis work. It never contains a command to be dispatched to a phone.
public struct WorkflowLearningJob: Codable, Identifiable, Sendable {
    public let id: UUID
    public let trace: WorkflowTrace
    /// pending jobs survive termination; compiled/rejected jobs retain their explicit outcome.
    public var state: String
    public var message: String?
}

/// A UI-independent durable queue, learned coordinate library, and revision control boundary.
public actor WorkflowLibrary {
    private struct Archive: Codable {
        var schema = 1
        var epoch = UUID()
        var workflows: [LearnedWorkflow] = []
        var jobs: [WorkflowLearningJob] = []
    }
    private let file: URL?
    private var archive: Archive?
    /// One compiler at a time, including while pure analysis runs outside this actor.
    private var processing = false
    public init(directory: URL?) { file = directory?.appendingPathComponent("workflows-v1.json") }

    private func read() throws -> Archive {
        if let archive { return archive }
        guard let file, FileManager.default.fileExists(atPath: file.path) else {
            let empty = Archive(); archive = empty; return empty
        }
        let info = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard info.isSymbolicLink != true, let size = info.fileSize, size <= 12 * 1024 * 1024 else { throw AssistantError.invalid("流程存档路径或大小无效，原文件未覆盖。") }
        let value: Archive
        do { value = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file)) }
        catch { throw AssistantError.invalid("流程存档损坏或不可读，未使用空流程替代。") }
        guard value.schema == 1, value.workflows.count <= 30, value.jobs.count <= 30,
              Set(value.workflows.map(\.id)).count == value.workflows.count,
              Set(value.jobs.map(\.id)).count == value.jobs.count,
              value.jobs.allSatisfy({ ["pending", "compiled", "rejected"].contains($0.state) }),
              value.workflows.allSatisfy({ ["candidate", "active", "disabled", "stale"].contains($0.state) && $0.successfulReplays >= 0 }) else {
            throw AssistantError.invalid("流程存档结构无效，原文件未覆盖。")
        }
        for item in value.workflows { try item.trace.validate() }
        archive = value; return value
    }
    private func commit(_ value: Archive) throws {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(value)
        guard data.count <= 12 * 1024 * 1024 else { throw AssistantError.invalid("流程库空间已满，请清理候选或学习记录。") }
        if let file {
            var directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
            #endif
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            try data.write(to: file, options: .atomic)
        }
        archive = value
    }
    public func epoch() throws -> UUID { try read().epoch }
    public func workflows() throws -> [LearnedWorkflow] { try read().workflows }
    public func jobs() throws -> [WorkflowLearningJob] { try read().jobs }
    /// New tasks see only published revisions; never a candidate still being compiled.
    public func active() throws -> [LearnedWorkflow] { try read().workflows.filter { $0.state == "active" } }
    public func requireActive(id: UUID, revision: UUID) throws {
        guard try read().workflows.contains(where: { $0.id == id && $0.revision == revision && $0.state == "active" }) else { throw AssistantError.conflict }
    }
    /// Atomic enqueue is the only synchronous persistence needed on the task-completion path.
    public func enqueue(_ trace: WorkflowTrace, expectedEpoch: UUID) throws {
        var value = try read()
        guard value.epoch == expectedEpoch else { throw AssistantError.conflict }
        guard !value.jobs.contains(where: { $0.id == trace.runID }) else { return }
        guard value.jobs.count < 30 else { throw AssistantError.invalid("学习队列已满，请先清理已处理记录。") }
        guard trace.steps.count <= 32 else { throw AssistantError.invalid("流程超过 32 步，请拆分为小流程。") }
        value.jobs.append(.init(id: trace.runID, trace: trace, state: "pending", message: nil))
        try commit(value)
    }
    /// Pure local compilation is asynchronous and resumable; it never calls a model or a device.
    public func processPending() async throws {
        guard !processing else { return }
        processing = true; defer { processing = false }
        while let job = try read().jobs.first(where: { $0.state == "pending" }) {
            let token = try read().epoch
            let analysis = await Task.detached(priority: .utility) { () -> String? in
                do { try job.trace.validate(); return nil }
                catch { return error.localizedDescription }
            }.value
            try Task.checkCancellation()
            var value = try read()
            // Deletion/edit while analysis was suspended cannot resurrect old evidence.
            guard value.epoch == token else { continue }
            guard let index = value.jobs.firstIndex(where: { $0.id == job.id && $0.state == "pending" }) else { continue }
            if let analysis {
                value.jobs[index].state = "rejected"; value.jobs[index].message = analysis
            } else if value.workflows.count >= 30 {
                value.jobs[index].state = "rejected"; value.jobs[index].message = "流程库已满；未丢弃或覆盖已有版本。"
            } else {
                // A whole trace is compiled; partial/failed tool sequences never become runnable.
                value.workflows.append(.init(id: UUID(), revision: UUID(), trace: job.trace, state: "candidate",
                                            successfulReplays: 0, lastFailure: nil, createdAt: Date()))
                value.jobs[index].state = "compiled"; value.jobs[index].message = "已生成候选；按钮坐标与页面证据待审核。"
            }
            try commit(value)
        }
    }
    /// A reviewed revision supersedes the previous named flow; older revisions remain available for review.
    public func activate(id: UUID, revision: UUID) throws {
        var value = try read()
        guard let index = value.workflows.firstIndex(where: { $0.id == id && $0.revision == revision }) else { throw AssistantError.conflict }
        guard value.workflows[index].state != "stale" else { throw AssistantError.invalid("此版本已因页面/版本变化失效，请执行纠正后重新学习。") }
        try value.workflows[index].trace.validate()
        let chosen = value.workflows[index].trace
        for i in value.workflows.indices where value.workflows[i].trace.name == chosen.name && value.workflows[i].trace.appBundleID == chosen.appBundleID {
            if value.workflows[i].state == "active" { value.workflows[i].state = "disabled" }
        }
        value.workflows[index].state = "active"; value.epoch = UUID(); try commit(value)
    }
    public func disable(id: UUID) throws {
        var value = try read()
        guard let index = value.workflows.firstIndex(where: { $0.id == id }) else { throw AssistantError.conflict }
        if value.workflows[index].state != "stale" { value.workflows[index].state = "disabled" }
        value.epoch = UUID(); try commit(value)
    }
    /// Drift quarantines this exact revision; transport errors remain explicit and are never retried here.
    public func recordReplay(id: UUID, revision: UUID, failure: String?, stale: Bool) throws {
        var value = try read()
        guard let index = value.workflows.firstIndex(where: { $0.id == id && $0.revision == revision }) else { throw AssistantError.conflict }
        if let failure {
            value.workflows[index].lastFailure = String(failure.prefix(1000))
            if stale { value.workflows[index].state = "stale" }
        } else { value.workflows[index].successfulReplays += 1; value.workflows[index].lastFailure = nil }
        try commit(value)
    }
    public func delete(id: UUID) throws {
        var value = try read(); value.workflows.removeAll { $0.id == id }; value.epoch = UUID(); try commit(value)
    }
    /// Disabling learning fences already-running analysis and makes pending work visibly cancelled.
    public func cancelPendingLearning() throws {
        var value = try read(); value.epoch = UUID()
        for index in value.jobs.indices where value.jobs[index].state == "pending" {
            value.jobs[index].state = "rejected"; value.jobs[index].message = "用户关闭学习，未继续生成候选。"
        }
        try commit(value)
    }
    public func clearProcessedJobs() throws {
        var value = try read(); value.jobs.removeAll { $0.state != "pending" }; try commit(value)
    }
    public func clear() throws { try commit(Archive()) }
}
