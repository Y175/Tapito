import Foundation

/// A delivered execution capability, never a successful scheduler submission.
/// Sources include SCK/USB health, a delivered system task, and active AVKit PiP.
@MainActor protocol RunBackgroundLease: AnyObject {
    var expirationHandler: (() -> Void)? { get set }
    var backgroundReady: Bool { get }
    /// A terminal source failure stops the task even in foreground; nil preserves normal expiry semantics.
    var failureMessage: String? { get }
    func prepareForCompletion()
    func report(completed: Int, subtitle: String)
    func complete(success: Bool)
}
extension RunBackgroundLease {
    var backgroundReady: Bool { true }
    var failureMessage: String? { nil }
    func prepareForCompletion() {}
}

@MainActor protocol RunBackgroundScheduler {
    var requiresSuccessfulSubmission: Bool { get }
    func setForeground(_ active: Bool)
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void) throws
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void,
                failed: @escaping @MainActor () -> Void) throws
    func cancel(identifier: String)
}
extension RunBackgroundScheduler {
    var requiresSuccessfulSubmission: Bool { false }
    func setForeground(_ active: Bool) {}
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void,
                failed: @escaping @MainActor () -> Void) throws { try submit(identifier: identifier, launched: launched) }
}
