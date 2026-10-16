import CoreLocation
import Combine
import Foundation

/// Explicit foreground setup for the task-only location mechanism. Coordinates are never retained.
@MainActor final class BackgroundLocationAccess: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = BackgroundLocationAccess()
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        refresh()
    }
    func refresh() { authorization = manager.authorizationStatus }
    var status: String {
        switch authorization {
        case .authorizedAlways: return "已允许始终定位"
        case .authorizedWhenInUse: return "还需改为“始终”允许"
        case .denied: return "定位权限已关闭"
        case .restricted: return "系统限制了定位权限"
        case .notDetermined: return "尚未授权"
        @unknown default: return "无法识别定位授权状态"
        }
    }
    /// Request only in response to the settings button; a background intent cannot prompt.
    func requestAuthorization() {
        refresh()
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
        else if authorization == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
    }
    func requireAuthorization() throws {
        refresh()
        guard authorization == .authorizedAlways else {
            throw AppError.unavailable("请先在 Tapito 设置 → 后台执行中，将定位权限设为“始终”允许，再开始任务")
        }
        guard CLLocationManager.locationServicesEnabled() else {
            throw AppError.unavailable("系统定位服务已关闭，请开启后再开始任务")
        }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.refresh() }
    }
}

/// No location values cross this boundary; tests can deliver lifecycle events without GPS.
@MainActor protocol TaskLocationDriving: AnyObject {
    var onReady: (() -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func start() throws
    func stop()
}

/// The same reduced-accuracy, non-pausing configuration validated in experiment A.
@MainActor final class CoreLocationTaskDriver: NSObject, TaskLocationDriving, CLLocationManagerDelegate {
    var onReady: (() -> Void)?
    var onFailure: ((String) -> Void)?
    private let manager = CLLocationManager()
    private var running = false
    override init() { super.init(); manager.delegate = self }
    func start() throws {
        try BackgroundLocationAccess.shared.requireAuthorization()
        guard (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("location") == true else {
            throw AppError.unavailable("安装包未声明后台定位能力")
        }
        manager.desiredAccuracy = kCLLocationAccuracyReduced
        manager.distanceFilter = kCLDistanceFilterNone
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        running = true
        manager.startUpdatingLocation()
    }
    func stop() {
        guard running else { return }
        running = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !locations.isEmpty else { return }
        // Discard coordinates on the delegate thread, before any diagnostic or task callback.
        Task { @MainActor [weak self] in
            guard let self, self.running else { return }
            self.onReady?()
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let failure = error as NSError
        let message = "后台定位失败（\(failure.domain)/\(failure.code)）；任务已停止，请检查定位权限与系统定位服务"
        Task { @MainActor [weak self] in
            guard let self, self.running else { return }
            self.onFailure?(message)
        }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self, self.running, self.manager.authorizationStatus != .authorizedAlways else { return }
            self.onFailure?("后台定位授权已撤销；任务已停止")
        }
    }
    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self, self.running else { return }
            self.onFailure?("系统已暂停后台定位；任务已停止，请手动重新开始")
        }
    }
}

/// A distinct manager per segment prevents an old stop from releasing another conversation.
@MainActor final class LocationRunScheduler: RunBackgroundScheduler {
    let requiresSuccessfulSubmission = true
    private let makeDriver: () -> any TaskLocationDriving
    private let startupTimeout: Duration
    private var leases: [String: LocationRunLease] = [:]
    init(startupTimeout: Duration = .seconds(20), makeDriver: @escaping () -> any TaskLocationDriving = { CoreLocationTaskDriver() }) {
        self.startupTimeout = startupTimeout; self.makeDriver = makeDriver
    }
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void) throws {
        guard leases[identifier] == nil else { throw AppError.invalid("后台定位片段重复提交") }
        let lease = LocationRunLease(identifier: identifier, driver: makeDriver(), startupTimeout: startupTimeout)
        try lease.start()
        leases[identifier] = lease
        launched(lease)
    }
    func cancel(identifier: String) { leases.removeValue(forKey: identifier)?.complete(success: false) }
}

/// Receiving a location callback confirms activation, not unlimited OS execution time.
@MainActor final class LocationRunLease: RunBackgroundLease {
    var expirationHandler: (() -> Void)?
    private(set) var backgroundReady = false
    private(set) var failureMessage: String?
    private let identifier: String
    private let driver: any TaskLocationDriving
    private let startupTimeout: Duration
    private var timeout: Task<Void, Never>?
    private var closed = false
    private var lastCompleted = -1
    private var startedAt = ProcessInfo.processInfo.systemUptime
    init(identifier: String, driver: any TaskLocationDriving, startupTimeout: Duration) {
        self.identifier = identifier; self.driver = driver; self.startupTimeout = startupTimeout
    }
    func start() throws {
        driver.onReady = { [weak self] in
            guard let self, !self.closed, !self.backgroundReady else { return }
            self.backgroundReady = true
            self.timeout?.cancel(); self.timeout = nil
            BackgroundExecutionTrace.record("location.ready segment=\(self.identifier) elapsedMs=\(self.elapsedMs)")
        }
        driver.onFailure = { [weak self] message in self?.fail(message) }
        do { try driver.start() }
        catch { complete(success: false); throw error }
        if closed { throw AppError.unavailable(failureMessage ?? "后台定位在启动时停止") }
        BackgroundExecutionTrace.record("location.start segment=\(identifier) audio=false coordinatesStored=false")
        guard !backgroundReady else { return }
        timeout = Task { [weak self, startupTimeout] in
            do { try await Task.sleep(for: startupTimeout) } catch { return }
            self?.fail("后台定位启动超时；未获得定位回调，任务已停止")
        }
    }
    private var elapsedMs: Int { Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000) }
    private func fail(_ message: String) {
        guard !closed else { return }
        failureMessage = message
        let callback = expirationHandler
        complete(success: false) // Revoke before notifying; never auto-renew a failed source.
        BackgroundExecutionTrace.record("location.failed segment=\(identifier) reason=\(message)")
        callback?()
    }
    func report(completed: Int, subtitle: String) {
        guard !closed, completed > lastCompleted else { return }
        lastCompleted = completed
        BackgroundExecutionTrace.record("location.progress segment=\(identifier) completed=\(completed) ready=\(backgroundReady) elapsedMs=\(elapsedMs)")
    }
    func complete(success: Bool) {
        guard !closed else { return }
        closed = true; backgroundReady = false
        timeout?.cancel(); timeout = nil
        driver.onReady = nil; driver.onFailure = nil
        driver.stop()
        expirationHandler = nil
        BackgroundExecutionTrace.record("location.stop segment=\(identifier) success=\(success) elapsedMs=\(elapsedMs)")
    }
}
