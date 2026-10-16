import Foundation
import Combine
import NetworkExtension
import TapitoConnectionKit

/// Apple API adapter for Tapito's own VPN profile. Never enumerates or edits another app's profile.
@MainActor final class EmbeddedLoopbackVPN: ObservableObject, LoopbackTunnel {
    static let providerID = "com.y175.tapito.LoopbackTunnel"
    @Published private(set) var enabled: Bool
    @Published private(set) var status: NEVPNStatus = .invalid
    private let defaults: UserDefaults
    private let configuration: () throws -> LoopbackConfiguration
    private var observer: AnyCancellable?
    private var manager: NETunnelProviderManager?
    init(defaults: UserDefaults = .standard, configuration: @escaping () throws -> LoopbackConfiguration) {
        self.defaults = defaults; self.configuration = configuration
        enabled = defaults.bool(forKey: "tapito.embeddedLoopback.enabled")
        observer = NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)
            .receive(on: DispatchQueue.main).sink { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let connection = notification.object as? NEVPNConnection,
                      connection === self.manager?.connection else { return }
                self.status = connection.status
                BackgroundExecutionTrace.record("connection.vpnStatus value=\(connection.status.rawValue)")
            }
        }
    }
    /// Foreground-only setup initiated by the user. Saving may show Apple's VPN consent sheet.
    func install() async throws {
        let config = try configuration()
        let existing = try await load()
        let manager = existing ?? NETunnelProviderManager()
        guard ![.connected, .connecting, .reasserting, .disconnecting].contains(manager.connection.status) else {
            throw ConnectionFailure("请先停止 Tapito VPN，再修改系统配置")
        }
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.providerID
        proto.serverAddress = config.peer
        proto.providerConfiguration = config.dictionary
        proto.includeAllNetworks = false
        proto.excludeLocalNetworks = false
        manager.localizedDescription = "Tapito 本机连接"
        manager.protocolConfiguration = proto
        manager.isEnabled = true
        manager.isOnDemandEnabled = false
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        self.manager = manager; status = manager.connection.status
        enabled = true; defaults.set(true, forKey: "tapito.embeddedLoopback.enabled")
        BackgroundExecutionTrace.record("connection.vpnConfigured version=1 internetRoute=false")
    }
    /// Returning to external mode affects only Tapito's own VPN and never deletes existing pairing.
    func useExternal() async throws {
        if let manager = try await load() {
            manager.connection.stopVPNTunnel()
            let limit = ContinuousClock.now.advanced(by: .seconds(10))
            while ![.disconnected, .invalid].contains(manager.connection.status) {
                guard ContinuousClock.now < limit else { throw ConnectionFailure("Tapito VPN 停止超时，未切换连接方式") }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        enabled = false; defaults.set(false, forKey: "tapito.embeddedLoopback.enabled")
    }
    /// Automatic starts require a previously approved, matching profile; no permission prompts in background.
    func start() async throws {
        guard enabled else { throw ConnectionFailure("请先在 Tapito 连接设置中启用内置 VPN") }
        let manager = try await configuredManager()
        switch manager.connection.status {
        case .connected: return
        case .disconnected:
            try manager.connection.startVPNTunnel()
        case .connecting, .reasserting: break
        case .invalid: throw ConnectionFailure("Tapito VPN 配置无效，请在连接设置中重新启用")
        case .disconnecting: throw ConnectionFailure("Tapito VPN 正在停止，请稍后重新连接")
        @unknown default: throw ConnectionFailure("无法识别系统 VPN 状态")
        }
        let limit = ContinuousClock.now.advanced(by: .seconds(20))
        var observedStarting = false
        while manager.connection.status != .connected {
            try Task.checkCancellation()
            guard ContinuousClock.now < limit else { throw ConnectionFailure("启动 Tapito VPN 超时") }
            // startVPNTunnel returns before the first status notification arrives.
            if [.connecting, .reasserting].contains(manager.connection.status) { observedStarting = true }
            guard ![.invalid, .disconnecting].contains(manager.connection.status),
                  !(observedStarting && manager.connection.status == .disconnected) else {
                throw ConnectionFailure("Tapito VPN 启动失败（系统状态 \(manager.connection.status.rawValue)）")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        status = manager.connection.status
    }
    func validate() async throws {
        let manager = try await configuredManager()
        guard manager.connection.status == .connected else { throw ConnectionFailure("Tapito 本机 VPN 已断开；未重新发送任何操作") }
    }
    private func load() async throws -> NETunnelProviderManager? {
        let matches = try await NETunnelProviderManager.loadAllFromPreferences().filter {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerID
        }
        guard matches.count <= 1 else { throw ConnectionFailure("存在多个 Tapito VPN 配置，请在系统 VPN 设置中处理重复项") }
        manager = matches.first; status = manager?.connection.status ?? .invalid
        return manager
    }
    private func configuredManager() async throws -> NETunnelProviderManager {
        guard let manager = try await load(), manager.isEnabled,
              let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
              let dictionary = proto.providerConfiguration else { throw ConnectionFailure("未找到已授权的 Tapito VPN 配置，请先在 App 中启用") }
        guard try LoopbackConfiguration(dictionary: dictionary) == configuration(), !proto.includeAllNetworks else {
            throw ConnectionFailure("Tapito VPN 系统配置与连接地址不一致；请停止连接后重新启用内置 VPN")
        }
        return manager
    }
}
