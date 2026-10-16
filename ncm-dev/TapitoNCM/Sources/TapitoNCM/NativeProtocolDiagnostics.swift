// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if os(iOS)
import AVFAudio
import UIKit
#endif

/// Dedicated bounded journal for fixed native protocol metadata, independent of UI activity logs.
/// It never accepts screen contents, peer error text, identities or request arguments.
@MainActor enum NativeProtocolDiagnostics {
    static let filename = "ncm-protocol-events.log"
    private static let categories: Set<String> = ["socket_eof", "socket_reset", "socket_broken_pipe", "socket_aborted", "socket_error", "device_error", "response_missing_field", "response_shape", "media_negotiation", "coredevice_error", "unexpected_response", "xpc_error", "typed_timeout", "typed_error"]

    /// Validates the native allowlist before atomic persistence. Missing source metadata is explicit.
    static func append(_ data: Data, requestID: UInt64, session: UUID, stage: UInt32, cause: UInt32, directory: URL? = nil) throws {
        let detail: String
        if data.isEmpty {
            detail = "TAPITO_VIDEO_NEGOTIATION result=source_unavailable"
        } else {
            guard data.count <= 1024, let line = String(data: data, encoding: .utf8),
                  !line.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw NativeBackendError.malformedEvent }
            let parts = line.split(separator: " ")
            guard parts.first == "TAPITO_VIDEO_NEGOTIATION" else { throw NativeBackendError.malformedEvent }
            var fields: [String: String] = [:]
            for part in parts.dropFirst() {
                let pair = part.split(separator: "=", omittingEmptySubsequences: false)
                guard pair.count == 2, fields[String(pair[0])] == nil else { throw NativeBackendError.malformedEvent }
                fields[String(pair[0])] = String(pair[1])
            }
            guard let result = fields["result"], ["ok", "error", "timeout"].contains(result),
                  let elapsed = fields["elapsedMs"], UInt64(elapsed) != nil else { throw NativeBackendError.malformedEvent }
            if result == "error" {
                let required: Set<String> = ["result", "code", "subcode", "category", "elapsedMs"]
                let peerKeys = Set(fields.keys).subtracting(required)
                guard required.isSubset(of: Set(fields.keys)),
                      let code = fields["code"], UInt32(code) != nil,
                      let subcode = fields["subcode"], UInt32(subcode) != nil,
                      let category = fields["category"], categories.contains(category) else { throw NativeBackendError.malformedEvent }
                if !peerKeys.isEmpty {
                    guard category == "device_error", let chain = fields["peerChain"],
                          ["complete", "truncated", "invalid_shape"].contains(chain) else { throw NativeBackendError.malformedEvent }
                    var expected: Set<String> = ["peerChain"]
                    var ended = false
                    for depth in 0..<3 {
                        let domainKey = "peer\(depth)Domain", codeKey = "peer\(depth)Code"
                        if let domain = fields[domainKey], let value = fields[codeKey] {
                            guard !ended, !domain.isEmpty, domain.utf8.count <= 80,
                                  domain.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }),
                                  value == "missing" || value == "invalid" || Int64(value) != nil || UInt64(value) != nil else { throw NativeBackendError.malformedEvent }
                            expected.insert(domainKey); expected.insert(codeKey)
                        } else { ended = true }
                    }
                    guard peerKeys == expected else { throw NativeBackendError.malformedEvent }
                }
            } else {
                guard Set(fields.keys) == Set(["result", "elapsedMs"]) else { throw NativeBackendError.malformedEvent }
            }
            detail = line
        }
        let folder = try directory ?? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(filename)
        var lines: [String] = []
        if FileManager.default.fileExists(atPath: file.path) {
            let info = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard info.isSymbolicLink != true, let size = info.fileSize, size <= 512 * 1024 else { throw NativeBackendError.malformedEvent }
            lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        }
        // Read actual process audio state at the request receipt. No route names,
        // microphone content or speech text enter this independent protocol journal.
        let context: String
        #if os(iOS)
        let audio = AVAudioSession.sharedInstance()
        context = " appState=\(UIApplication.shared.applicationState.rawValue) audioCategory=\(audio.category.rawValue) audioMode=\(audio.mode.rawValue) audioOptions=\(audio.categoryOptions.rawValue) inputAvailable=\(audio.isInputAvailable) otherAudio=\(audio.isOtherAudioPlaying)"
        #else
        context = ""
        #endif
        lines.append("\(Date().ISO8601Format()) session=\(session.uuidString) request=\(requestID) stage=\(stage) cause=\(cause) \(detail)\(context)")
        // Bound by bytes as well as lines: additional error-chain fields must
        // evict oldest records rather than make a healthy request fail on log size.
        lines = Array(lines.suffix(1000))
        var bytes = lines.reduce(0) { $0 + $1.utf8.count + 1 }
        while bytes > 512 * 1024, lines.count > 1 { bytes -= lines.removeFirst().utf8.count + 1 }
        let output = Data((lines.joined(separator: "\n") + "\n").utf8)
        guard output.count <= 512 * 1024 else { throw NativeBackendError.malformedEvent }
        #if os(iOS)
        try output.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try output.write(to: file, options: .atomic)
        #endif
        var excluded = file, values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }
}
