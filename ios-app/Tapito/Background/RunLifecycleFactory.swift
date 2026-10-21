import Foundation

@MainActor enum RunLifecycleFactory {
    static func make(persistent: Bool, scheduler: any RunBackgroundScheduler, directory: URL? = nil) -> RunLifecycleCoordinator {
        let storage: any RunCheckpointStorage
        if persistent {
            do { storage = try RunCheckpointStore(directory: directory) }
            catch { storage = UnavailableCheckpointStore() }
        } else { storage = MemoryRunCheckpointStore() }
        return RunLifecycleCoordinator(scheduler: scheduler, storage: storage)
    }
}
@MainActor private struct UnavailableCheckpointStore: RunCheckpointStorage {
    func load() throws -> RunCheckpoint? { throw AppError.unavailable("检查点不可用") }
    func save(_ checkpoint: RunCheckpoint) throws { throw AppError.unavailable("检查点不可用") }
}
