import Foundation

/// An asynchronous extraction job; page evidence has already had all non-interface text removed.
public struct AssistantLearningJob: Codable, Identifiable, Sendable {
    public let id: UUID
    public let workspaceEpoch: UUID
    public let userText: String
    public let providerID: UUID
    /// Frozen provider endpoint/account identity; the host rejects changed destinations.
    public let providerScope: String
    public let model: String
    public let transitions: [PageTransitionEvidence]
    public var state: String
    public var message: String?
    /// Reject corrupted or cross-run evidence before it reaches either analysis role.
    public func validate() throws {
        guard userText.count <= 20000, !providerScope.isEmpty, !model.isEmpty, transitions.count <= 32,
              ["pending", "completed", "failed", "rejected"].contains(state),
              Set(transitions.map(\.id)).count == transitions.count,
              transitions.allSatisfy({ $0.runID == id }) else { throw AssistantError.invalid("学习任务来源、状态或证据归属无效。") }
        for transition in transitions { try transition.validate() }
    }
}

/// A proposed personal fact must retain an exact quote from the job's original user message.
public struct MemoryProposal: Codable, Sendable {
    public let key: String
    public let content: String
    public let scope: String
    public let evidence: String
    public let revision: UUID?
}

/// Model annotations never supply executable coordinates; the host binds the referenced evidence.
public struct CapabilityAnnotation: Codable, Sendable {
    /// Host-created transition ID. The model cannot substitute its own screen or coordinate evidence.
    public let evidenceID: UUID
    /// General page/function descriptions exclude current-task content.
    public let pageName: String
    public let function: String
    public let observedResult: String
    public init(evidenceID: UUID, pageName: String, function: String, observedResult: String) {
        self.evidenceID = evidenceID; self.pageName = pageName; self.function = function; self.observedResult = observedResult
    }
}

/// Durable reviewed page knowledge plus an explicitly resumable model-analysis queue.
public actor KnowledgeLibrary {
    private struct Archive: Codable {
        var schema = 1
        var epoch = UUID()
        var capabilities: [PageCapability] = []
        var jobs: [AssistantLearningJob] = []
    }
    private let file: URL?
    private var archive: Archive?
    private var processing = false
    public init(directory: URL?) { file = directory?.appendingPathComponent("agent-knowledge-v1.json") }

    private func read() throws -> Archive {
        if let archive { return archive }
        guard let file, FileManager.default.fileExists(atPath: file.path) else {
            let value = Archive(); archive = value; return value
        }
        let info = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard info.isSymbolicLink != true, let size = info.fileSize, size <= 8 * 1024 * 1024 else {
            throw AssistantError.invalid("页面知识存档路径或大小无效。")
        }
        let value: Archive
        do { value = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file)) }
        catch { throw AssistantError.invalid("页面知识存档损坏；原文件保留，未替换为空白数据。") }
        guard value.schema == 1, value.capabilities.count <= 300, value.jobs.count <= 100,
              Set(value.capabilities.map(\.id)).count == value.capabilities.count,
              Set(value.jobs.map(\.id)).count == value.jobs.count,
              value.jobs.allSatisfy({ ["pending", "completed", "failed", "rejected"].contains($0.state) }) else {
            throw AssistantError.invalid("页面知识版本、数量或任务状态无效。")
        }
        for item in value.capabilities { try item.validate() }
        for job in value.jobs { try job.validate() }
        archive = value; return value
    }
    private func commit(_ value: Archive) throws {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(value)
        guard data.count <= 8 * 1024 * 1024 else { throw AssistantError.invalid("页面知识存档已满，请清理已处理记录。") }
        if let file {
            var directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var flags = URLResourceValues(); flags.isExcludedFromBackup = true
            try directory.setResourceValues(flags)
            #if os(iOS)
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: file, options: .atomic)
            #endif
        }
        archive = value
    }
    public func capabilities() throws -> [PageCapability] { try read().capabilities }
    public func active() throws -> [PageCapability] { try read().capabilities.filter { $0.state == "active" } }
    public func jobs() throws -> [AssistantLearningJob] { try read().jobs }
    public func epoch() throws -> UUID { try read().epoch }
    public func requireActive(id: UUID, revision: UUID) throws {
        guard try active().contains(where: { $0.id == id && $0.revision == revision }) else { throw AssistantError.conflict }
    }
    /// Sources are copied once; duplicate task completion cannot enqueue a second extraction.
    public func enqueue(runID: UUID, workspaceEpoch: UUID, expectedEpoch: UUID, userText: String,
                        providerID: UUID, providerScope: String, model: String, transitions: [PageTransitionEvidence]) throws {
        var value = try read()
        guard value.epoch == expectedEpoch else { throw AssistantError.conflict }
        if value.jobs.contains(where: { $0.id == runID }) { return }
        guard value.jobs.count < 100, userText.count <= 20000, !model.isEmpty, !providerScope.isEmpty, transitions.count <= 32 else {
            throw AssistantError.invalid("学习队列容量、任务文本、模型或证据数量无效。")
        }
        for transition in transitions { try transition.validate() }
        let job = AssistantLearningJob(id: runID, workspaceEpoch: workspaceEpoch, userText: userText,
            providerID: providerID, providerScope: providerScope, model: model, transitions: transitions, state: "pending", message: nil)
        try job.validate(); value.jobs.append(job)
        try commit(value)
    }
    /// The host supplies a separately owned model client; analysis has no device-control port.
    public func processPending(workspace: AssistantWorkspace, diagnostic: @Sendable (String) -> Void = { _ in },
                               analyze: @Sendable (AssistantLearningJob, [AssistantMemory]) async throws -> ([MemoryProposal], [CapabilityAnnotation])) async throws {
        guard !processing else { return }
        processing = true; defer { processing = false }
        while let job = try read().jobs.first(where: { $0.state == "pending" }) {
            let epoch = try read().epoch
            let started = Date()
            diagnostic("knowledge.job.started id=\(job.id) evidence=\(job.transitions.count)")
            do {
                guard try await workspace.epoch() == job.workspaceEpoch,
                      try await workspace.automaticMemoryEnabled() else { throw AssistantError.conflict }
                let memories = try await workspace.search(query: job.userText)
                let (facts, annotations) = try await analyze(job, memories)
                try Task.checkCancellation()
                guard try read().epoch == epoch else { try rejectPending(job.id); continue }
                guard facts.count <= 8, annotations.count <= job.transitions.count,
                      Set(annotations.map(\.evidenceID)).count == annotations.count else {
                    throw AssistantError.invalid("学习模型输出条目过多或证据重复。")
                }
                let candidates = try annotations.map { annotation -> PageCapability in
                    guard let evidence = job.transitions.first(where: { $0.id == annotation.evidenceID }) else {
                        throw AssistantError.invalid("技能学习引用不存在的操作证据。")
                    }
                    let item = PageCapability(evidence: evidence, pageName: annotation.pageName,
                                              function: annotation.function, observedResult: annotation.observedResult)
                    try item.validate(); return item
                }
                let existingCapabilities = try read().capabilities
                let novel = candidates.filter { candidate in
                    !existingCapabilities.contains { old in
                        let a = old.evidence, b = candidate.evidence
                        return a.appBundleID == b.appBundleID && a.appVersion == b.appVersion && a.systemVersion == b.systemVersion &&
                            a.action == b.action && a.control == b.control && a.before.width == b.before.width && a.before.height == b.before.height &&
                            a.before.anchors == b.before.anchors && a.after.anchors == b.after.anchors
                    }
                }
                guard existingCapabilities.count + novel.count <= 300 else { throw AssistantError.invalid("页面能力库已满。") }
                // Both outputs are validated before writes. Personal facts are idempotent by source run.
                // Cross-file I/O failures are explicit; a job is never silently reported as completed.
                try await workspace.applyLearning(facts, userText: job.userText, runID: job.id, expectedEpoch: job.workspaceEpoch)
                var value = try read()
                guard value.epoch == epoch else { try rejectPending(job.id); continue }
                guard let index = value.jobs.firstIndex(where: { $0.id == job.id && $0.state == "pending" }) else { continue }
                guard value.capabilities.count + novel.count <= 300 else { throw AssistantError.invalid("页面能力库已满。") }
                value.capabilities.append(contentsOf: novel)
                value.jobs[index].state = "completed"
                value.jobs[index].message = "新增 \(facts.count) 条记忆、\(novel.count) 个页面能力候选；候选需审核。"
                try commit(value)
                diagnostic("knowledge.job.completed id=\(job.id) memories=\(facts.count) candidates=\(novel.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
            } catch {
                if Task.isCancelled || error is CancellationError { throw error }
                var value = try read()
                guard value.epoch == epoch else { try rejectPending(job.id); continue }
                guard let index = value.jobs.firstIndex(where: { $0.id == job.id && $0.state == "pending" }) else { continue }
                value.jobs[index].state = (error as? AssistantError) == .conflict ? "rejected" : "failed"
                value.jobs[index].message = String(error.localizedDescription.prefix(500))
                try commit(value)
                diagnostic("knowledge.job.failed id=\(job.id) state=\(value.jobs[index].state) errorType=\(String(describing: type(of: error)))")
            }
        }
    }
    private func rejectPending(_ id: UUID) throws {
        var value = try read()
        guard let index = value.jobs.firstIndex(where: { $0.id == id && $0.state == "pending" }) else { return }
        value.jobs[index].state = "rejected"
        value.jobs[index].message = "知识库已由用户修改；旧分析输出已丢弃，不会重新生成被删除内容。"
        try commit(value)
    }
    /// Review is explicit; same-page/same-control revisions supersede the old active revision.
    public func activate(id: UUID, revision: UUID) throws {
        var value = try read()
        guard let index = value.capabilities.firstIndex(where: { $0.id == id && $0.revision == revision }),
              value.capabilities[index].state != "stale" else { throw AssistantError.conflict }
        let chosen = value.capabilities[index]
        try chosen.validate()
        for i in value.capabilities.indices {
            let old = value.capabilities[i]
            if old.state == "active", old.evidence.appBundleID == chosen.evidence.appBundleID,
               old.evidence.control == chosen.evidence.control, old.evidence.action == chosen.evidence.action,
               try old.evidence.before.matches(chosen.evidence.before) { value.capabilities[i].state = "disabled" }
        }
        value.capabilities[index].state = "active"; value.epoch = UUID(); try commit(value)
    }
    /// A verified version/page mismatch removes this revision from subsequent routing catalogs.
    public func markStale(id: UUID, revision: UUID) throws {
        var value = try read()
        guard let index = value.capabilities.firstIndex(where: { $0.id == id && $0.revision == revision }) else { throw AssistantError.conflict }
        // Quarantine does not revoke new evidence collected by this same correcting run.
        value.capabilities[index].state = "stale"; try commit(value)
    }
    public func disable(id: UUID) throws {
        var value = try read()
        guard let index = value.capabilities.firstIndex(where: { $0.id == id }) else { throw AssistantError.conflict }
        value.capabilities[index].state = "disabled"; value.epoch = UUID(); try commit(value)
    }
    public func delete(id: UUID) throws {
        var value = try read(); value.capabilities.removeAll { $0.id == id }; value.epoch = UUID(); try commit(value)
    }
    public func clearProcessed() throws {
        var value = try read(); value.jobs.removeAll { $0.state != "pending" }; try commit(value)
    }
    public func clear() throws { try commit(Archive()) }
}
