import Foundation
import XCTest
import ProviderCore
import OpenAIAdapter

final class ProviderEndpointTests: XCTestCase {
    func testPrivateIPv4RangesAllowExplicitHTTP() throws {
        for host in ["10.0.0.1", "10.255.255.254", "172.16.0.1", "172.31.255.254", "192.168.0.1", "192.168.255.254"] {
            XCTAssertTrue(ProviderEndpointPolicy.allows(try XCTUnwrap(URL(string: "http://\(host):8317/prefix/v1"))), host)
        }
    }

    func testPublicAndAmbiguousHTTPAddressesAreRejected() throws {
        for host in ["9.255.255.254", "11.0.0.1", "172.15.255.254", "172.32.0.1", "192.167.1.1", "192.169.1.1",
                     "8.8.8.8", "100.64.0.1", "169.254.1.1", "127.0.0.1", "0.0.0.0", "localhost", "proxy.local",
                     "10.0.0.1.example.com", "10.1", "010.0.0.1", "0x0a000001", "167772161", "[::1]", "[fd00::1]"] {
            XCTAssertFalse(ProviderEndpointPolicy.allows(try XCTUnwrap(URL(string: "http://\(host)/v1"))), host)
        }
    }

    func testCredentialsQueriesFragmentsAndInvalidPortsRemainRejected() throws {
        for address in ["http://user:secret@10.0.0.1/v1", "http://10.0.0.1/v1?key=secret", "http://10.0.0.1/v1#fragment",
                        "http://10.0.0.1:0/v1", "http://10.0.0.1:65536/v1", "ftp://10.0.0.1/v1",
                        "https://user:secret@example.com/v1", "https://example.com/v1?key=secret", "https://example.com/v1#fragment"] {
            XCTAssertFalse(ProviderEndpointPolicy.allows(try XCTUnwrap(URL(string: address))), address)
        }
        XCTAssertTrue(ProviderEndpointPolicy.allows(try XCTUnwrap(URL(string: "https://api.openai.com/v1"))))
    }

    func testBothWireProtocolsBuildLocalHTTPRequestsWithExplicitCredentials() throws {
        let base = try XCTUnwrap(URL(string: "http://10.10.15.46:8317/prefix/v1"))
        for wire in [OpenAIWireProtocol.chatCompletions, .responses] {
            let codec = OpenAIWireCodec(configuration: .init(name: "fixture", baseURL: base, apiKey: "synthetic", defaultModel: "fixture"), wire: wire)
            let request = try codec.prepareRequest(.init(model: "fixture", messages: [.user("test")]), stream: true)
            XCTAssertEqual(request.url?.absoluteString, base.absoluteString + (wire == .responses ? "/responses" : "/chat/completions"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        }
    }

    func testWireProtocolsCannotBypassAddressPolicy() throws {
        for address in ["http://example.com/v1", "http://8.8.8.8/v1", "http://user:secret@10.0.0.1/v1", "http://10.0.0.1/v1?key=secret"] {
            for wire in [OpenAIWireProtocol.chatCompletions, .responses] {
                let codec = OpenAIWireCodec(configuration: .init(name: "fixture", baseURL: try XCTUnwrap(URL(string: address))), wire: wire)
                XCTAssertThrowsError(try codec.prepareRequest(.init(model: "fixture", messages: [.user("test")]), stream: false))
            }
        }
    }
}
