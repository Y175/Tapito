// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum NCMError: String, Error, LocalizedError {
    case interfaceUnavailable, interfaceAmbiguous, interfaceInvalid, interfaceScopeUnsupported
    case busy, timeout, disconnected, network, malformedReply, unavailableBackend
    public var errorDescription: String? { rawValue }
}
/// Implementations must own an
/// authenticated generation, negotiated IPv6/RSD endpoint, DDI checks, and media.
/// NativeDeveloperServices links the real backend; no device access happens until
/// explicitly connected with an authorized identity and permissions.
@MainActor public protocol DeveloperServices {
    func listServices() async throws -> [String]
    func capturePNG() async throws -> Data
    /// Must hold an authenticated DisplayService media session; scoped to this authenticated session.
    /// A transport ACK alone must not be reported as visible input success.
    func tap(x: UInt16, y: UInt16) async throws
}
@MainActor public struct UnavailableDeveloperServices: DeveloperServices {
    public init() {}
    public func listServices() async throws -> [String] { throw NCMError.unavailableBackend }
    public func capturePNG() async throws -> Data { throw NCMError.unavailableBackend }
    public func tap(x: UInt16, y: UInt16) async throws { throw NCMError.unavailableBackend }
}
