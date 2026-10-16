import XCTest
#if canImport(Tapito)
@testable import Tapito
#else
@testable import IntentHost
#endif

/// Exercises the production scope and lifecycle without granting real OS execution time.
final class IntentExecutionTests: XCTestCase {
    @MainActor func testPendingAndCancelledEntryCannotDispatch() async throws {
        let scope = IntentRunExecutionScope(progress: Progress(), diagnostic: { _ in })
        XCTAssertThrowsError(try scope.submit(identifier: "pending") { _ in XCTFail("ungranted") })
        scope.close(success: false)
        XCTAssertThrowsError(try scope.activate())
        XCTAssertThrowsError(try scope.submit(identifier: "cancelled") { _ in XCTFail("cancelled") })
    }

    @MainActor func testExpiryRevokesBeforeCallbackAndCannotRenew() async throws {
        let scope = IntentRunExecutionScope(progress: Progress(), diagnostic: { _ in })
        try scope.activate()
        var delivered: (any RunBackgroundLease)?
        try scope.submit(identifier: "run") { delivered = $0 }
        let lease = try XCTUnwrap(delivered)
        var callbacks = 0
        var renewalError: Error?
        lease.expirationHandler = {
            callbacks += 1
            XCTAssertFalse(lease.backgroundReady)
            do { try scope.submit(identifier: "renew") { _ in XCTFail("renewed") } }
            catch { renewalError = error }
        }
        scope.close(success: false)
        scope.close(success: false)
        XCTAssertEqual(callbacks, 1)
        XCTAssertNotNil(renewalError)
    }

    @MainActor func testCompletionDoesNotEndAnotherLeaseOrNextTurn() async throws {
        let scope = IntentRunExecutionScope(progress: Progress(), diagnostic: { _ in })
        try scope.activate()
        var first: (any RunBackgroundLease)?
        var second: (any RunBackgroundLease)?
        try scope.submit(identifier: "first") { first = $0 }
        try scope.submit(identifier: "second") { second = $0 }
        first?.complete(success: true)
        scope.cancel(identifier: "first")
        XCTAssertTrue(try XCTUnwrap(second).backgroundReady)
        second?.complete(success: true)
        try scope.submit(identifier: "next") { XCTAssertTrue($0.backgroundReady) }
        scope.close(success: false)
    }

    @MainActor func testOnlyActualReceiptsAdvanceProgressAcrossTurns() async throws {
        let progress = Progress()
        let scope = IntentRunExecutionScope(progress: progress, diagnostic: { _ in })
        try scope.activate()
        for _ in 0..<5 { scope.setStatus("正在聆听") }
        XCTAssertEqual(progress.completedUnitCount, 0)
        XCTAssertTrue(progress.isIndeterminate)
        var first: (any RunBackgroundLease)?
        try scope.submit(identifier: "first") { first = $0 }
        first?.report(completed: 2, subtitle: "two receipts")
        first?.report(completed: 2, subtitle: "duplicate")
        XCTAssertEqual(progress.completedUnitCount, 2)
        first?.complete(success: true)
        first?.report(completed: 9, subtitle: "late")
        var next: (any RunBackgroundLease)?
        try scope.submit(identifier: "next") { next = $0 }
        next?.report(completed: 1, subtitle: "next turn")
        XCTAssertEqual(progress.completedUnitCount, 3)
        next?.complete(success: true)
        scope.close(success: true)
        XCTAssertTrue(progress.isFinished)
    }

    @MainActor func testLateCancellationCannotCloseReplacementScope() async throws {
        let old = IntentRunExecutionScope(progress: Progress(), diagnostic: { _ in })
        let next = IntentRunExecutionScope(progress: Progress(), diagnostic: { _ in })
        try old.activate(); old.close(success: true)
        try next.activate()
        var lease: (any RunBackgroundLease)?
        try next.submit(identifier: "next") { lease = $0 }
        old.close(success: false)
        XCTAssertTrue(try XCTUnwrap(lease).backgroundReady)
        next.close(success: false)
    }

    @MainActor func testDuplicateSubmissionDoesNotReplaceLease() async throws {
        let scope = IntentRunExecutionScope(progress: Progress(), diagnostic: { _ in })
        try scope.activate()
        var first: (any RunBackgroundLease)?
        try scope.submit(identifier: "same") { first = $0 }
        XCTAssertThrowsError(try scope.submit(identifier: "same") { _ in XCTFail("duplicate accepted") })
        XCTAssertTrue(try XCTUnwrap(first).backgroundReady)
        scope.close(success: false)
    }

    @MainActor func testProgressRegressionFailsVisiblyAndRevokesGrant() async throws {
        var events: [String] = []
        let scope = IntentRunExecutionScope(progress: Progress(), diagnostic: { events.append($0) })
        try scope.activate()
        var lease: (any RunBackgroundLease)?
        try scope.submit(identifier: "run") { lease = $0 }
        var expired = false
        lease?.expirationHandler = { expired = true }
        lease?.report(completed: 3, subtitle: "three")
        lease?.report(completed: 1, subtitle: "invalid regression")
        XCTAssertTrue(expired)
        XCTAssertTrue(events.contains { $0.contains("failure=receiptRegression") })
        XCTAssertThrowsError(try scope.submit(identifier: "again") { _ in XCTFail("invalid grant") })
    }

    @MainActor func testBackgroundLifecycleRequiresLiveIntentAndPreservesUnknownInput() async throws {
        let scope = IntentRunExecutionScope(progress: Progress(), diagnostic: { _ in })
        let lifecycle = RunLifecycleCoordinator(scheduler: scope, storage: MemoryRunCheckpointStore())
        let generation = UUID()
        let identity = RunIdentity(conversationID: UUID(), runID: UUID())
        try scope.activate()
        lifecycle.setForeground(false)
        try lifecycle.begin(identity: identity, generation: generation, allowBackgroundStart: true)
        try await lifecycle.awaitExecution(generation: generation, backgroundCapable: true)
        let input = RunCheckpoint.Tool(callID: "input", name: "type_text", parameterSummary: "", argumentDigest: "hash")
        try lifecycle.prepare(input, generation: generation, backgroundCapable: true)
        try lifecycle.dispatch(callID: input.callID, generation: generation, backgroundCapable: true)
        var pauses = 0
        lifecycle.onPause = { _ in pauses += 1 }
        scope.close(success: false)
        XCTAssertEqual(pauses, 1)
        XCTAssertEqual(lifecycle.checkpoint?.phase, .paused)
        XCTAssertEqual(lifecycle.checkpoint?.tools.first?.delivery, .outcomeUnknown)
        XCTAssertThrowsError(try lifecycle.requireExecution(generation: generation, backgroundCapable: true))
        XCTAssertThrowsError(try lifecycle.acknowledge(callID: input.callID, generation: generation))
    }

    @MainActor func testFinishedRunDoesNotRevokeContinuousConversationGrant() async throws {
        let scope = IntentRunExecutionScope(progress: Progress(), diagnostic: { _ in })
        let lifecycle = RunLifecycleCoordinator(scheduler: scope, storage: MemoryRunCheckpointStore())
        try scope.activate()
        lifecycle.setForeground(false)
        for _ in 0..<2 {
            let generation = UUID()
            try lifecycle.begin(identity: RunIdentity(conversationID: UUID(), runID: UUID()), generation: generation, allowBackgroundStart: true)
            try await lifecycle.awaitExecution(generation: generation, backgroundCapable: true)
            lifecycle.finish(success: true)
            XCTAssertEqual(lifecycle.checkpoint?.phase, .completed)
        }
        scope.close(success: true)
    }
}
