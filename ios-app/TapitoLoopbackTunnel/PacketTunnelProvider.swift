import NetworkExtension
import TapitoConnectionKit
import os

/// Local packet reflection only. No DNS override, remote server, or Internet proxy is installed.
// All mutable provider state is confined to queue; NetworkExtension owns packetFlow synchronization.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.y175.tapito.loopback.packets")
    /// Fences callbacks from an earlier start/stop cycle.
    private var epoch = UUID()
    private let log = Logger(subsystem: "com.y175.tapito.LoopbackTunnel", category: "lifecycle")

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        do {
            guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
                  let dictionary = proto.providerConfiguration else { throw ConnectionFailure("回环扩展缺少配置") }
            let config = try LoopbackConfiguration(dictionary: dictionary)
            let reflector = try IPv4LoopbackReflector(configuration: config)
            let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: config.peer)
            let ipv4 = NEIPv4Settings(addresses: [config.interface], subnetMasks: ["255.255.255.0"])
            ipv4.includedRoutes = [NEIPv4Route(destinationAddress: config.peer, subnetMask: "255.255.255.255")]
            ipv4.excludedRoutes = [.default()]
            settings.ipv4Settings = ipv4
            setTunnelNetworkSettings(settings) { error in
                if let error { completionHandler(error); return }
                self.queue.async {
                    let token = UUID(); self.epoch = token
                    self.log.notice("loopback.started configVersion=1 internetRoute=false")
                    self.readPackets(reflector: reflector, epoch: token)
                    completionHandler(nil)
                }
            }
        } catch { completionHandler(error) }
    }
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.async {
            self.epoch = UUID()
            self.log.notice("loopback.stopped reason=\(reason.rawValue)")
            completionHandler()
        }
    }
    private func readPackets(reflector: IPv4LoopbackReflector, epoch token: UUID) {
        packetFlow.readPackets { packets, protocols in
            self.queue.async {
                guard self.epoch == token else { return }
                do {
                    guard packets.count == protocols.count else { throw ConnectionFailure("回环包与协议数量不一致") }
                    let reflected = try zip(packets, protocols).map { packet, family in
                        guard family.int32Value == AF_INET else { throw ConnectionFailure("回环收到未配置的地址族") }
                        return try reflector.reflect(packet)
                    }
                    if !reflected.isEmpty, !self.packetFlow.writePackets(reflected, withProtocols: protocols) {
                        throw ConnectionFailure("系统拒绝回注本机数据包")
                    }
                    self.readPackets(reflector: reflector, epoch: token)
                } catch {
                    self.epoch = UUID()
                    self.log.error("loopback.failed reason=\(error.localizedDescription, privacy: .public)")
                    self.cancelTunnelWithError(error)
                }
            }
        }
    }
}
