// Retained for regression coverage of the retired LongRunningIntent path.
// Production voice entry and task routing no longer reference this scope.
import Foundation

/// Execution authority exists only inside a system-delivered LongRunningIntent operation.
/// Constructing this object or reporting progress does not request/renew system time.
@MainActor final class IntentRunExecutionScope: RunBackgroundScheduler {
    /// Correlates grants, leases and cancellation without storing speech or model content.
    let id = UUID()
    private enum State { case pending, active, closed }
    /// Pending also lets cancellation arriving before operation entry fence activation.
    private var state: State = .pending
    private let progress: Progress
    private let diagnostic: (String) -> Void
    /// Each run has its own lease; completion cannot end another run or the outer intent.
    private var leases: [String: IntentRunLease] = [:]
    private var completedReceipts: Int64 = 0

    init(progress: Progress, diagnostic: @escaping (String) -> Void) {
        self.progress = progress; self.diagnostic = diagnostic
    }

    /// Call exactly once, from within performBackgroundTask's operation closure.
    func activate() throws {
        guard state == .pending else { throw AppError.unavailable("后台语音授权已取消或重复进入") }
        state = .active
        // An adaptive agent cannot predict its step count. Never invent a percentage
        // or advance a timer to make an idle task appear to be progressing.
        progress.totalUnitCount = -1; progress.completedUnitCount = 0
        progress.localizedDescription = "Tapito 语音任务"
        setStatus("正在准备语音")
        diagnostic("execution.intentGranted scope=\(id)")
    }

    func setStatus(_ status: String) {
        guard state == .active else { return }
        progress.localizedAdditionalDescription = status
    }

    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void) throws {
        guard state == .active else { throw AppError.unavailable("后台语音执行授权已结束；请重新按操作按钮") }
        guard leases[identifier] == nil else { throw AppError.invalid("后台语音片段重复提交") }
        let lease = IntentRunLease(owner: self, identifier: identifier)
        leases[identifier] = lease
        diagnostic("execution.intentLease scope=\(id) segment=\(identifier)")
        launched(lease)
    }

    func cancel(identifier: String) { leases[identifier]?.complete(success: false) }

    /// Revoke before notifying clients: a reentrant submission cannot obtain a new lease.
    func close(success: Bool) {
        guard state != .closed else { return }
        let wasActive = state == .active
        state = .closed
        let outstanding = Array(leases.values)
        leases.removeAll()
        for lease in outstanding { lease.expire() }
        if success && wasActive && outstanding.isEmpty {
            progress.localizedAdditionalDescription = "语音会话已结束"
            progress.totalUnitCount = max(1, completedReceipts)
            progress.completedUnitCount = progress.totalUnitCount
        }
        if success && !outstanding.isEmpty {
            diagnostic("execution.intentInvariant scope=\(id) failure=undrained")
        }
        diagnostic("execution.intentClosed scope=\(id) active=\(wasActive) drained=\(outstanding.isEmpty) success=\(success && outstanding.isEmpty)")
    }

    fileprivate func invalidProgress() {
        diagnostic("execution.intentInvariant scope=\(id) failure=receiptRegression")
        close(success: false)
    }

    fileprivate func report(_ lease: IntentRunLease, delta: Int, subtitle: String) {
        guard state == .active, leases[lease.identifier] === lease else { return }
        completedReceipts += Int64(delta)
        progress.completedUnitCount = completedReceipts
        progress.localizedAdditionalDescription = subtitle
        if delta > 0 { diagnostic("execution.intentProgress scope=\(id) receipts=\(completedReceipts)") }
    }

    fileprivate func release(_ lease: IntentRunLease) {
        guard leases[lease.identifier] === lease else { return }
        leases.removeValue(forKey: lease.identifier)
    }
}

/// A per-run view of the enclosing intent grant, not a separate OS background request.
@MainActor private final class IntentRunLease: RunBackgroundLease {
    let identifier: String
    private weak var owner: IntentRunExecutionScope?
    private var ended = false
    private var lastCompleted = 0
    var expirationHandler: (() -> Void)?
    var backgroundReady: Bool { !ended && owner != nil }

    init(owner: IntentRunExecutionScope, identifier: String) {
        self.owner = owner; self.identifier = identifier
    }

    func report(completed: Int, subtitle: String) {
        guard !ended, let owner else { return }
        // Coordinator receipts are cumulative within a run. Duplicate delivery is
        // not new progress; a new run may restart its own counter at zero.
        guard completed >= lastCompleted else { owner.invalidProgress(); return }
        let delta = completed - lastCompleted
        lastCompleted = completed
        owner.report(self, delta: delta, subtitle: subtitle)
    }

    func complete(success: Bool) {
        guard !ended else { return }
        ended = true; expirationHandler = nil
        owner?.release(self); owner = nil
    }

    func expire() {
        guard !ended else { return }
        let callback = expirationHandler
        complete(success: false)
        callback?()
    }
}
