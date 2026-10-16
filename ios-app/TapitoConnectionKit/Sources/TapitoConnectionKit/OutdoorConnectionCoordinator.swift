import Foundation

/// System VPN lifecycle only. This boundary knows nothing about UI, voice, or agent execution.
@MainActor public protocol LoopbackTunnel: AnyObject {
    func start() async throws
    func validate() async throws
}

/// Adapts the existing paired-device backend without moving its keys or replaying operations.
@MainActor public protocol PairedControlConnection: AnyObject {
    var isReady: Bool { get }
    func reserve(_ ticket: UUID) throws
    func connect(_ ticket: UUID) async throws
    func validate(_ ticket: UUID) async throws
    func release(_ ticket: UUID, keepConnection: Bool)
}

/// The app supplies its independently managed execution mechanism; the connection core owns its duration.
@MainActor public protocol ConnectionExecutionLifetime: AnyObject {
    var onFailure: (() -> Void)? { get set }
    func begin() async throws
    func end()
}

/// Structured result returned before Shortcuts restores the radio, including ordinary connection failures.
public struct OfflineConnectionReceipt: Codable, Equatable, Sendable {
    public let ticket: UUID
    public let failure: String?
    public init(ticket: UUID, failure: String?) { self.ticket = ticket; self.failure = failure }
}

/// Two-phase outdoor bootstrap. Radio switches remain system Shortcuts actions, never private APIs.
@MainActor public final class OutdoorConnectionCoordinator {
    public enum Phase: String, Sendable { case idle, startingVPN, awaitingOffline, connecting, awaitingNetwork, checking, ready, failed }
    public private(set) var phase: Phase = .idle
    /// Redacted stage events are consumed by the host app's diagnostic sink.
    public var onPhase: ((Phase) -> Void)?
    private let tunnel: any LoopbackTunnel
    private let connection: any PairedControlConnection
    private let lifetime: any ConnectionExecutionLifetime
    private let isOffline: () async throws -> Bool
    private let hasNetwork: () async throws -> Bool
    private let timeout: Duration
    private var active: UUID?
    private var receipt: OfflineConnectionReceipt?
    private var expiry: Task<Void, Never>?
    public init(tunnel: any LoopbackTunnel, connection: any PairedControlConnection,
                lifetime: any ConnectionExecutionLifetime, timeout: Duration = .seconds(120),
                isOffline: @escaping () async throws -> Bool, hasNetwork: @escaping () async throws -> Bool) {
        self.tunnel = tunnel; self.connection = connection; self.lifetime = lifetime
        self.timeout = timeout; self.isOffline = isOffline; self.hasNetwork = hasNetwork
    }
    /// Called while cellular is still available. "ready" instructs the template to skip radio changes.
    public func prepare() async throws -> String {
        guard active == nil else { throw ConnectionFailure("已有连接初始化正在进行，请先完成或取消") }
        let ticket = UUID()
        try connection.reserve(ticket)
        active = ticket; receipt = nil
        lifetime.onFailure = { [weak self] in self?.cancel() }
        expiry = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.active == ticket else { return }
            self.cancel()
        }
        do {
            if connection.isReady {
                try await connection.validate(ticket)
                try require(ticket)
                finish(ticket, success: true)
                return "ready"
            }
            setPhase(.startingVPN)
            try await lifetime.begin(); try require(ticket)
            try await tunnel.start(); try require(ticket)
            setPhase(.awaitingOffline)
            return ticket.uuidString
        } catch {
            if active == ticket { finish(ticket, success: false) }
            throw error
        }
    }
    /// This method returns errors as data so the next shortcut action can always restore airplane mode.
    public func connectOffline(ticket: UUID) async -> OfflineConnectionReceipt {
        // Repeated/foreign callbacks must not replace the current operation's authoritative receipt.
        guard active == ticket, phase == .awaitingOffline else {
            return OfflineConnectionReceipt(ticket: ticket, failure: "离线连接步骤已失效、重复或顺序错误")
        }
        do {
            try require(ticket)
            setPhase(.connecting)
            guard try await isOffline() else { throw ConnectionFailure("仍存在蜂窝或 Wi-Fi 连接；请先完成离线切换") }
            try require(ticket)
            try await tunnel.validate(); try require(ticket)
            try await connection.connect(ticket); try require(ticket)
            let result = OfflineConnectionReceipt(ticket: ticket, failure: nil)
            receipt = result; setPhase(.awaitingNetwork)
            return result
        } catch {
            let result = OfflineConnectionReceipt(ticket: ticket, failure: error.localizedDescription)
            if active == ticket { receipt = result; setPhase(.awaitingNetwork) }
            return result
        }
    }
    /// Called only AFTER the system action restores the network. Never reconnects a failed session.
    public func finishAfterNetworkRestored(_ result: OfflineConnectionReceipt) async throws {
        try require(result.ticket)
        guard phase == .awaitingNetwork, receipt == result else { throw ConnectionFailure("初始化回执不匹配；请重新开始") }
        do {
            if let failure = result.failure { throw ConnectionFailure(failure) }
            setPhase(.checking)
            guard try await hasNetwork() else { throw ConnectionFailure("网络尚未恢复；请关闭飞行模式并检查蜂窝网络") }
            try require(result.ticket)
            try await tunnel.validate(); try require(result.ticket)
            try await connection.validate(result.ticket); try require(result.ticket)
            finish(result.ticket, success: true)
        } catch {
            if active == result.ticket { finish(result.ticket, success: false) }
            throw error
        }
    }
    /// Ends only this initialization, never another run's execution lifetime.
    public func cancel() {
        guard let ticket = active else { return }
        finish(ticket, success: false)
    }
    private func require(_ ticket: UUID) throws {
        try Task.checkCancellation()
        guard active == ticket else { throw ConnectionFailure("连接初始化已过期或 App 已重启；请确认飞行模式已关闭后重新开始") }
    }
    private func finish(_ ticket: UUID, success: Bool) {
        guard active == ticket else { return }
        active = nil; receipt = nil; expiry?.cancel(); expiry = nil
        lifetime.onFailure = nil; lifetime.end()
        connection.release(ticket, keepConnection: success)
        setPhase(success ? .ready : .failed)
    }
    private func setPhase(_ value: Phase) { phase = value; onPhase?(value) }
}
