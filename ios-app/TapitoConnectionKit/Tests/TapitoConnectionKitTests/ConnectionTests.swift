import XCTest
@testable import TapitoConnectionKit

@MainActor final class OutdoorConnectionTests: XCTestCase {
    private final class Fixture: LoopbackTunnel, PairedControlConnection, ConnectionExecutionLifetime {
        var isReady = false
        var onFailure: (() -> Void)?
        var events: [String] = []
        var failStart = false
        var failConnect = false
        var failValidate = false
        var reservation: UUID?
        var suspension: CheckedContinuation<Void, Never>?
        var suspendConnect = false
        func start() async throws { events.append("vpn.start"); if failStart { throw ConnectionFailure("VPN rejected") } }
        func validate() async throws { events.append("vpn.validate") }
        func reserve(_ ticket: UUID) throws { guard reservation == nil else { throw ConnectionFailure("busy") }; reservation = ticket; events.append("reserve") }
        func connect(_ ticket: UUID) async throws {
            events.append("connect")
            if suspendConnect { await withCheckedContinuation { suspension = $0 } }
            if failConnect { throw ConnectionFailure("pairing failed") }
            guard reservation == ticket else { throw ConnectionFailure("old callback") }
            isReady = true
        }
        func validate(_ ticket: UUID) async throws {
            events.append("device.validate")
            if failValidate { throw ConnectionFailure("connection lost") }
        }
        func release(_ ticket: UUID, keepConnection: Bool) { if reservation == ticket { reservation = nil; isReady = keepConnection; events.append("release.\(keepConnection)") } }
        func begin() async throws { events.append("lifetime.begin") }
        func end() { events.append("lifetime.end") }
    }
    private func make(_ f: Fixture, offline: Bool = true, restored: Bool = true, timeout: Duration = .seconds(120)) -> OutdoorConnectionCoordinator {
        OutdoorConnectionCoordinator(tunnel: f, connection: f, lifetime: f, timeout: timeout,
            isOffline: { offline }, hasNetwork: { restored })
    }
    private func ticket(_ coordinator: OutdoorConnectionCoordinator) async throws -> UUID {
        let value = try await coordinator.prepare()
        return try XCTUnwrap(UUID(uuidString: value))
    }
    func testSuccessfulTwoPhaseConnectionRetainsSessionAndReleasesLease() async throws {
        let f = Fixture()
        let coordinator = make(f), id = try await ticket(coordinator)
        XCTAssertEqual(coordinator.phase, .awaitingOffline)
        let result = await coordinator.connectOffline(ticket: id)
        XCTAssertNil(result.failure)
        XCTAssertEqual(coordinator.phase, .awaitingNetwork)
        XCTAssertFalse(f.events.contains("lifetime.end"))
        try await coordinator.finishAfterNetworkRestored(result)
        XCTAssertEqual(f.events, ["reserve", "lifetime.begin", "vpn.start", "vpn.validate", "connect", "vpn.validate", "device.validate", "lifetime.end", "release.true"])
        XCTAssertEqual(coordinator.phase, .ready)
    }
    func testExistingConnectionSkipsVPNAndRadioChanges() async throws {
        let f = Fixture(); f.isReady = true
        let c = make(f)
        let value = try await c.prepare()
        XCTAssertEqual(value, "ready")
        XCTAssertFalse(f.events.contains("vpn.start")); XCTAssertFalse(f.events.contains("lifetime.begin"))
    }
    func testStartFailureOccursBeforeOfflinePhaseAndReleasesReservation() async {
        let f = Fixture(); f.failStart = true
        let c = make(f)
        do { _ = try await c.prepare(); XCTFail() } catch { XCTAssertEqual(error.localizedDescription, "VPN rejected") }
        XCTAssertNil(f.reservation); XCTAssertEqual(c.phase, .failed)
        XCTAssertFalse(f.events.contains("connect"))
    }
    func testOfflineFailureIsReturnedBeforeNetworkRestorationAndNeverRetried() async throws {
        let f = Fixture(); f.failConnect = true
        let c = make(f), id = try await ticket(c)
        let result = await c.connectOffline(ticket: id)
        XCTAssertEqual(result.failure, "pairing failed"); XCTAssertEqual(c.phase, .awaitingNetwork)
        do { try await c.finishAfterNetworkRestored(result); XCTFail() } catch { XCTAssertEqual(error.localizedDescription, "pairing failed") }
        XCTAssertEqual(f.events.filter { $0 == "connect" }.count, 1)
        XCTAssertEqual(f.events.last, "release.false")
    }
    func testStillOnlineDoesNotAttemptHandshake() async throws {
        let f = Fixture()
        let coordinator = make(f, offline: false), id = try await ticket(coordinator)
        let result = await coordinator.connectOffline(ticket: id)
        XCTAssertNotNil(result.failure); XCTAssertFalse(f.events.contains("connect")); coordinator.cancel()
    }
    func testDuplicateOfflineCallCannotReplaceSuccessfulReceipt() async throws {
        let f = Fixture()
        let coordinator = make(f), id = try await ticket(coordinator)
        let result = await coordinator.connectOffline(ticket: id)
        let duplicate = await coordinator.connectOffline(ticket: id)
        XCTAssertNotNil(duplicate.failure)
        try await coordinator.finishAfterNetworkRestored(result)
        XCTAssertEqual(coordinator.phase, .ready)
        XCTAssertEqual(f.events.filter { $0 == "connect" }.count, 1)
    }
    func testForeignReceiptDoesNotCancelActiveInitialization() async throws {
        let f = Fixture()
        let coordinator = make(f), id = try await ticket(coordinator)
        do { try await coordinator.finishAfterNetworkRestored(.init(ticket: UUID(), failure: nil)); XCTFail() } catch {}
        XCTAssertEqual(f.reservation, id); XCTAssertEqual(coordinator.phase, .awaitingOffline)
        coordinator.cancel()
    }
    func testLostConnectionAfterRadioRestorationFailsWithoutReconnect() async throws {
        let f = Fixture()
        let coordinator = make(f), id = try await ticket(coordinator)
        let result = await coordinator.connectOffline(ticket: id)
        f.failValidate = true
        do { try await coordinator.finishAfterNetworkRestored(result); XCTFail() } catch {}
        XCTAssertEqual(f.events.filter { $0 == "connect" }.count, 1)
        XCTAssertEqual(f.events.last, "release.false")
    }
    func testNetworkNotRestoredDoesNotClaimReady() async throws {
        let f = Fixture(), c = make(f, restored: false), id = try await ticket(c)
        let result = await c.connectOffline(ticket: id)
        do { try await c.finishAfterNetworkRestored(result); XCTFail() } catch {}
        XCTAssertEqual(c.phase, .failed)
    }
    func testLeaseRevocationStopsWithoutRenewal() async throws {
        let f = Fixture(), c = make(f), id = try await ticket(c)
        f.onFailure?()
        let result = await c.connectOffline(ticket: id)
        XCTAssertNotNil(result.failure); XCTAssertEqual(c.phase, .failed)
        XCTAssertFalse(f.events.contains("connect")); XCTAssertEqual(f.events.filter { $0 == "lifetime.begin" }.count, 1)
    }
    func testTimeoutRevokesTicket() async throws {
        let f = Fixture(), c = make(f, timeout: .milliseconds(20)), id = try await ticket(c)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(f.reservation)
        let result = await c.connectOffline(ticket: id)
        XCTAssertNotNil(result.failure)
    }
    func testCancelledCallbackCannotMutateNextInitialization() async throws {
        let f = Fixture(), c = make(f), first = try await ticket(c)
        f.suspendConnect = true
        let pending = Task { await c.connectOffline(ticket: first) }
        while f.suspension == nil { await Task.yield() }
        c.cancel()
        f.suspendConnect = false
        let second = try await ticket(c)
        f.suspension?.resume(); f.suspension = nil
        let late = await pending.value
        XCTAssertNotNil(late.failure)
        XCTAssertEqual(c.phase, .awaitingOffline); XCTAssertEqual(f.reservation, second)
        c.cancel()
    }
}

final class LoopbackPacketTests: XCTestCase {
    func testRejectsMalformedOrMissingConfiguration() throws {
        for address in ["127.0.0.1", "0.2.3.4", "224.0.0.1", "10.07.0.1", "10.7.0", "::1"] {
            XCTAssertThrowsError(try LoopbackConfiguration(interface: address, peer: "10.7.0.1"))
        }
        XCTAssertThrowsError(try LoopbackConfiguration(dictionary: ["interface": "10.7.1.1", "peer": "10.7.0.1"]))
        XCTAssertEqual(try LoopbackConfiguration(dictionary: LoopbackConfiguration.standard.dictionary), .standard)
    }
    private var packet: Data { Data([0x45, 0, 0, 24, 0, 0, 0, 0, 64, 6, 0, 0, 10, 7, 1, 1, 10, 7, 0, 1, 1, 2, 3, 4]) }
    func testReflectionPreservesPayloadAndChecksumSum() throws {
        let reflector = try IPv4LoopbackReflector(configuration: .standard)
        let reflected = try reflector.reflect(packet)
        XCTAssertEqual(Array(reflected[12..<16]), [10, 7, 0, 1])
        XCTAssertEqual(Array(reflected[16..<20]), [10, 7, 1, 1])
        XCTAssertEqual(reflected[20...], packet[20...])
        func sum(_ data: Data) -> Int { stride(from: 0, to: 20, by: 2).reduce(0) { $0 + Int(data[$1]) * 256 + Int(data[$1 + 1]) } }
        XCTAssertEqual(sum(reflected), sum(packet))
    }
    func testRejectsUnrelatedDestinationsAndInvalidPackets() throws {
        let reflector = try IPv4LoopbackReflector(configuration: .standard)
        var wrong = packet; wrong[16] = 8
        XCTAssertThrowsError(try reflector.reflect(wrong))
        XCTAssertThrowsError(try reflector.reflect(packet.prefix(19)))
        wrong = packet; wrong[0] = 0x65
        XCTAssertThrowsError(try reflector.reflect(wrong))
        wrong = packet; wrong[3] = 25
        XCTAssertThrowsError(try reflector.reflect(wrong))
    }
}
