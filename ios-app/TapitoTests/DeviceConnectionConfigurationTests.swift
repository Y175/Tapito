import XCTest
@testable import Tapito

@MainActor final class DeviceConnectionConfigurationTests: XCTestCase {

    func testVPNAddressSaveIsAtomicRevokesSessionAndRetainsIdentity() async throws {
        let suite = "VPNConfigTests.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "identity.plist"), bytes = Data("identity-sentinel".utf8)
        try bytes.write(to: url)
        let store = RemotePairRecordStore(url: url), flow = PairingFlow(store: store, defaults: defaults)
        XCTAssertEqual(flow.vpnConfiguration, .defaults)
        let session = flow.controlSessionID
        XCTAssertThrowsError(try flow.saveVPNConfiguration(localAddress: "invalid", peerAddress: "10.8.0.1"))
        XCTAssertEqual(flow.controlSessionID, session)
        XCTAssertEqual(flow.vpnConfiguration, .defaults)
        flow.ready = true
        try flow.saveVPNConfiguration(localAddress: "10.8.1.1", peerAddress: "10.8.0.1")
        XCTAssertFalse(flow.ready); XCTAssertNotEqual(flow.controlSessionID, session)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(PairingFlow(store: store, defaults: defaults).vpnConfiguration, flow.vpnConfiguration)
        let bridge = try NCMDeviceBridge(flow: flow)
        XCTAssertThrowsError(try flow.saveVPNConfiguration(localAddress: "10.9.1.1", peerAddress: "10.9.0.1"))
        XCTAssertEqual(flow.vpnConfiguration.localAddress, "10.8.1.1")
        await bridge.stop()
    }
}
