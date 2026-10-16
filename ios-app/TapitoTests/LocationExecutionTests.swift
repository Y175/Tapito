import XCTest
@testable import Tapito

/// Exercises production ownership, rejection, stop and stale callbacks without GPS permission prompts.
final class LocationExecutionTests: XCTestCase {
    @MainActor private final class Driver: TaskLocationDriving {
        var onReady: (() -> Void)?
        var onFailure: ((String) -> Void)?
        var starts = 0
        var stops = 0
        var denied = false
        func start() throws {
            starts += 1
            if denied { throw AppError.unavailable("定位权限不足") }
        }
        func stop() { stops += 1 }
    }
    @MainActor private final class Audio: TaskAudioPlayback {
        var onStopped: (() -> Void)?
        var starts = 0
        func start() async throws -> Bool { starts += 1; return true }
        func stop() {}
    }
    @MainActor func testRequiresReceiptAndStopFencesLateCallbacks() throws {
        let driver = Driver(), scheduler = LocationRunScheduler(makeDriver: { driver })
        var received: (any RunBackgroundLease)?
        try scheduler.submit(identifier: "first") { received = $0 }
        let lease = try XCTUnwrap(received)
        XCTAssertFalse(lease.backgroundReady)
        let lateReady = driver.onReady, lateFailure = driver.onFailure
        driver.onReady?()
        XCTAssertTrue(lease.backgroundReady)
        scheduler.cancel(identifier: "first")
        lateReady?(); lateFailure?("old error")
        XCTAssertFalse(lease.backgroundReady)
        XCTAssertNil(lease.failureMessage)
        lease.complete(success: true)
        XCTAssertEqual(driver.stops, 1)
    }
    @MainActor func testPermissionFailureRejectsRunBeforeAnyExecution() throws {
        let driver = Driver(); driver.denied = true
        let scheduler = LocationRunScheduler(makeDriver: { driver })
        let lifecycle = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
        let generation = UUID()
        XCTAssertThrowsError(try lifecycle.begin(identity: RunIdentity(conversationID: UUID(), runID: UUID()), generation: generation)) {
            XCTAssertEqual($0.localizedDescription, "定位权限不足")
        }
        XCTAssertFalse(lifecycle.hasLease)
        XCTAssertEqual(lifecycle.checkpoint?.phase, .paused)
        XCTAssertThrowsError(try lifecycle.requireExecution(generation: generation, backgroundCapable: true))
        XCTAssertEqual(driver.stops, 1)
    }
    @MainActor func testFailureRevokesBeforeCallbackAndNeverRenewsInForeground() throws {
        let driver = Driver(), scheduler = LocationRunScheduler(makeDriver: { driver })
        let lifecycle = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
        let generation = UUID()
        try lifecycle.begin(identity: RunIdentity(conversationID: UUID(), runID: UUID()), generation: generation)
        driver.onReady?()
        var reason: String?
        lifecycle.onPause = { reason = $0 }
        driver.onFailure?("定位已停止")
        XCTAssertEqual(reason, "定位已停止")
        XCTAssertEqual(lifecycle.checkpoint?.phase, .paused)
        XCTAssertFalse(lifecycle.hasLease)
        XCTAssertEqual(driver.starts, 1)
        XCTAssertEqual(driver.stops, 1)
        XCTAssertThrowsError(try lifecycle.requireExecution(generation: generation, backgroundCapable: true))
    }
    @MainActor func testBackgroundDispatchWaitsForLocationReceipt() async throws {
        let driver = Driver(), scheduler = LocationRunScheduler(makeDriver: { driver })
        let lifecycle = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
        let generation = UUID()
        lifecycle.setForeground(false)
        try lifecycle.begin(identity: RunIdentity(conversationID: UUID(), runID: UUID()), generation: generation, allowBackgroundStart: true)
        var dispatched = false
        let pending = Task { @MainActor in
            try await lifecycle.awaitExecution(generation: generation, backgroundCapable: true)
            dispatched = true
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(dispatched)
        driver.onReady?()
        try await pending.value
        XCTAssertTrue(dispatched)
        lifecycle.finish(success: true)
        XCTAssertEqual(driver.stops, 1)
    }
    @MainActor func testStartupTimeoutStopsPendingRun() async throws {
        let driver = Driver(), scheduler = LocationRunScheduler(startupTimeout: .milliseconds(20), makeDriver: { driver })
        let lifecycle = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
        lifecycle.setForeground(false)
        try lifecycle.begin(identity: RunIdentity(conversationID: UUID(), runID: UUID()), generation: UUID(), allowBackgroundStart: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(lifecycle.checkpoint?.phase, .paused)
        XCTAssertTrue(lifecycle.backgroundStatus.contains("启动超时"))
        XCTAssertEqual(driver.stops, 1)
    }
    @MainActor func testOldRunCannotReleaseNewRunAndDispatchingIsNotReplayed() throws {
        let first = Driver(), second = Driver()
        var drivers = [first, second]
        let scheduler = LocationRunScheduler(makeDriver: { drivers.removeFirst() })
        let storage = MemoryRunCheckpointStore()
        let lifecycle = RunLifecycleCoordinator(scheduler: scheduler, storage: storage)
        let generation = UUID()
        try lifecycle.begin(identity: RunIdentity(conversationID: UUID(), runID: UUID()), generation: generation)
        let oldID = try XCTUnwrap(lifecycle.checkpoint?.segmentID)
        first.onReady?()
        try lifecycle.prepare(.init(callID: "input", name: "tap", parameterSummary: "", argumentDigest: "digest"), generation: generation, backgroundCapable: true)
        try lifecycle.dispatch(callID: "input", generation: generation, backgroundCapable: true)
        lifecycle.stop(message: "用户停止")
        XCTAssertEqual(storage.value?.tools.first?.delivery, .outcomeUnknown)
        try lifecycle.begin(identity: RunIdentity(conversationID: UUID(), runID: UUID()), generation: UUID())
        second.onReady?()
        scheduler.cancel(identifier: oldID)
        XCTAssertEqual(first.stops, 1)
        XCTAssertEqual(second.stops, 0)
        XCTAssertTrue(lifecycle.hasLease)
        lifecycle.finish(success: true)
        XCTAssertEqual(second.stops, 1)
    }
    @MainActor func testProductionRoutingChoosesLocationForVoiceAndText() throws {
        for voice in [false, true] {
            let driver = Driver()
            let location = LocationRunScheduler(makeDriver: { driver })
            let scheduler = RunExecutionScheduler(location: location)
            scheduler.configure(context: nil, allowSystemProcessing: true, audioFree: voice, useLocation: true)
            XCTAssertTrue(scheduler.requiresSuccessfulSubmission)
            try scheduler.submit(identifier: "run") { _ in }
            XCTAssertEqual(driver.starts, 1)
            // A later configuration change cannot redirect the old run's stop.
            scheduler.configure(context: nil, allowSystemProcessing: false)
            scheduler.cancel(identifier: "run")
            XCTAssertEqual(driver.stops, 1)
        }
    }
    @MainActor func testLocationPolicySuppressesOldSavedMediaResidency() async throws {
        let audio = Audio()
        let media = StatusPiPController(executionActivity: PiPExecutionActivity(), audioPlayback: audio)
        media.useLocationExecution()
        media.setBackgroundMode(.audio)
        media.setBackgroundResident(true)
        media.setTaskRunning(true)
        media.setForeground(false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(audio.starts, 0)
        XCTAssertFalse(media.audioActive)
        XCTAssertFalse(media.policy.running)
    }
}
