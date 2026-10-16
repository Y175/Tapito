import Foundation

/// Shared address policy for provider discovery, saved settings and inference.
/// Cleartext is limited to explicitly entered RFC 1918 IPv4 literals; public
/// hosts, DNS aliases and loopback addresses still require HTTPS.
public enum ProviderEndpointPolicy {
    /// Checks the base address before any request can attach credentials.
    public static func allows(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return false }
        if parts.scheme == "https" { return true }
        guard parts.scheme == "http" else { return false }
        // Do not resolve names or accept abbreviated/octal IPv4 spellings:
        // the displayed address must identify exactly the permitted endpoint.
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count == 4 else { return false }
        var octets: [UInt8] = []
        for label in labels {
            guard let octet = UInt8(label), String(octet) == label else { return false }
            octets.append(octet)
        }
        return octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }
}
