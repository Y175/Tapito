import Foundation

/// Versioned wire contract shared by the containing app and its packet tunnel.
public struct LoopbackConfiguration: Equatable, Sendable {
    /// Local address of the virtual interface, deliberately distinct from the peer.
    public let interface: String
    /// Only this /32 destination is routed into the reflector; Internet traffic is excluded.
    public let peer: String
    public static let standard = try! LoopbackConfiguration(interface: "10.7.1.1", peer: "10.7.0.1")
    public init(interface: String, peer: String) throws {
        _ = try Self.octets(interface); _ = try Self.octets(peer)
        guard interface != peer else { throw ConnectionFailure("回环接口和对端地址不能相同") }
        self.interface = interface; self.peer = peer
    }
    public init(dictionary: [String: Any]) throws {
        guard dictionary["version"] as? Int == 1,
              let interface = dictionary["interface"] as? String,
              let peer = dictionary["peer"] as? String else { throw ConnectionFailure("回环 VPN 配置缺失或版本不支持") }
        try self.init(interface: interface, peer: peer)
    }
    public var dictionary: [String: Any] { ["version": 1, "interface": interface, "peer": peer] }
    static func octets(_ address: String) throws -> [UInt8] {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        let values = parts.compactMap { UInt8($0) }
        guard values.count == 4, zip(parts, values).allSatisfy({ String($0.1) == String($0.0) }),
              values[0] != 0, values[0] != 127, values[0] < 224,
              values != [255, 255, 255, 255] else { throw ConnectionFailure("回环 VPN 地址必须是有效的单播 IPv4 地址") }
        return values
    }
}

/// Errors cross UI/Intent boundaries as explicit messages, without protocol payloads or credentials.
public struct ConnectionFailure: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A bounded local IPv4 reflector, independently testable without Network Extension privileges.
public struct IPv4LoopbackReflector: Sendable {
    private let source: [UInt8]
    private let destination: [UInt8]
    public init(configuration: LoopbackConfiguration) throws {
        source = try LoopbackConfiguration.octets(configuration.interface)
        destination = try LoopbackConfiguration.octets(configuration.peer)
    }
    /// Swapping addresses preserves IPv4 and TCP/UDP pseudo-header sums. No remote forwarding occurs.
    public func reflect(_ packet: Data) throws -> Data {
        var bytes = [UInt8](packet)
        guard bytes.count >= 20, bytes[0] >> 4 == 4 else { throw ConnectionFailure("拒绝非 IPv4 回环包") }
        let headerSize = Int(bytes[0] & 15) * 4
        let length = Int(bytes[2]) * 256 + Int(bytes[3])
        guard headerSize >= 20, headerSize <= bytes.count, length == bytes.count,
              Array(bytes[12..<16]) == source, Array(bytes[16..<20]) == destination else {
            throw ConnectionFailure("拒绝地址不匹配或长度无效的回环包")
        }
        bytes.replaceSubrange(12..<16, with: destination)
        bytes.replaceSubrange(16..<20, with: source)
        return Data(bytes)
    }
}
