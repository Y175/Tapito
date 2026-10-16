import Foundation
import Combine
import Network
import TapitoConnectionKit

/// Connection composition root. UI and Intents use this facade, with no dependency on Agent/voice types.
@MainActor final class DeviceConnectionServices: ObservableObject {
    static let shared = DeviceConnectionServices()
    let vpn: EmbeddedLoopbackVPN
    let outdoor: OutdoorConnectionCoordinator
    @Published private(set) var outdoorPhase: OutdoorConnectionCoordinator.Phase = .idle
    private let flow: PairingFlow
    private init() {
        let flow = PairingFlow.shared
        self.flow = flow
        let vpn = EmbeddedLoopbackVPN {
            try LoopbackConfiguration(interface: flow.vpnConfiguration.localAddress, peer: flow.vpnConfiguration.peerAddress)
        }
        self.vpn = vpn
        outdoor = OutdoorConnectionCoordinator(tunnel: vpn, connection: PairedConnectionAdapter(flow: flow),
            lifetime: BootstrapExecutionLifetime(), isOffline: { try await PhysicalNetworkCheck.wait(connected: false) },
            hasNetwork: { try await PhysicalNetworkCheck.wait(connected: true) })
        flow.prepareLoopback = { if vpn.enabled { try await vpn.start() } }
        outdoor.onPhase = { [weak self] phase in
            self?.outdoorPhase = phase
            BackgroundExecutionTrace.record("connection.outdoor phase=\(phase.rawValue)")
        }
    }
    func enableEmbeddedVPN() async throws {
        let ticket = UUID()
        try flow.reserveConnectionBootstrap(ticket, requiresPairing: false)
        do {
            try await vpn.install()
            flow.releaseConnectionBootstrap(ticket, keepConnection: false)
        } catch {
            flow.releaseConnectionBootstrap(ticket, keepConnection: true)
            throw error
        }
    }
    func useExternalVPN() async throws {
        let ticket = UUID()
        try flow.reserveConnectionBootstrap(ticket, requiresPairing: false)
        do {
            try await vpn.useExternal()
            flow.releaseConnectionBootstrap(ticket, keepConnection: false)
        } catch {
            flow.releaseConnectionBootstrap(ticket, keepConnection: false)
            throw error
        }
    }
}

/// Only this adapter knows the existing paired-device backend; a future backend replaces this adapter.
@MainActor private final class PairedConnectionAdapter: PairedControlConnection {
    private let flow: PairingFlow
    init(flow: PairingFlow) { self.flow = flow }
    var isReady: Bool { flow.ready }
    func reserve(_ ticket: UUID) throws { try flow.reserveConnectionBootstrap(ticket) }
    func connect(_ ticket: UUID) async throws { try await flow.connectForBootstrap(ticket) }
    func validate(_ ticket: UUID) async throws { try await flow.validateBootstrap(ticket) }
    func release(_ ticket: UUID, keepConnection: Bool) { flow.releaseConnectionBootstrap(ticket, keepConnection: keepConnection) }
}

/// Holds a separate A execution lease, never microphone/audio or a conversation's lease.
@MainActor private final class BootstrapExecutionLifetime: ConnectionExecutionLifetime {
    var onFailure: (() -> Void)?
    private var lease: LocationRunLease?
    func begin() async throws {
        guard lease == nil else { throw ConnectionFailure("初始化后台片段重复启动") }
        let grant = LocationRunLease(identifier: "connection." + UUID().uuidString,
            driver: CoreLocationTaskDriver(), startupTimeout: .seconds(20))
        lease = grant
        grant.expirationHandler = { [weak self] in self?.onFailure?() }
        try grant.start()
        while !grant.backgroundReady {
            guard lease === grant, grant.failureMessage == nil else {
                throw ConnectionFailure(grant.failureMessage ?? "初始化后台执行已停止")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    func end() { lease?.complete(success: true); lease = nil }
}

/// Physical-path evidence, not an inference that an arbitrary VPN path means cellular has recovered.
@MainActor private final class PhysicalNetworkCheck {
    private let cellular = NWPathMonitor(requiredInterfaceType: .cellular)
    private let wifi = NWPathMonitor(requiredInterfaceType: .wifi)
    private var cellularState: NWPath.Status?
    private var wifiState: NWPath.Status?
    private init() {
        cellular.pathUpdateHandler = { [weak self] path in Task { @MainActor in self?.cellularState = path.status } }
        wifi.pathUpdateHandler = { [weak self] path in Task { @MainActor in self?.wifiState = path.status } }
        cellular.start(queue: DispatchQueue(label: "tapito.connection.cellular"))
        wifi.start(queue: DispatchQueue(label: "tapito.connection.wifi"))
    }
    static func wait(connected: Bool) async throws -> Bool {
        let check = PhysicalNetworkCheck()
        defer { check.cellular.cancel(); check.wifi.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(connected ? 20 : 8))
        while ContinuousClock.now < deadline {
            if let cellular = check.cellularState, let wifi = check.wifiState,
               ((cellular == .satisfied || wifi == .satisfied) == connected) { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}
