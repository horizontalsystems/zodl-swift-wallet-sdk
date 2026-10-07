import Combine
import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class CompactBlockProcessorCleanupTests: ZcashTestCase {
    func testCleanupCompletesWhenCancelledFinalActionReturnsNormally() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        _ = try await fixture.redeemer.check()
        let processor = fixture.synchronizer.blockProcessor
        let entered = XCTestExpectation(description: "real final action entered")
        let admitted = XCTestExpectation(description: "teardown stopped downloader")
        let finished = XCTestExpectation(description: "cleanup finished")
        let gate = GiftCardOperationGate()
        fixture.repository.findForResubmissionUpToClosure = { _ in
            entered.fulfill()
            await gate.wait()
            return []
        }
        await routeToFinalAction(processor)
        await processor.start()
        await fulfillment(of: [entered], timeout: 5)
        let checkpoint = CleanupEvents()
        fixture.downloader.stopDownloadClosure = {
            if checkpoint.appendOnce("stop") { admitted.fulfill() }
        }
        let cleanup = Task {
            defer { finished.fulfill() }
            try await fixture.redeemer.cleanup()
        }
        await fulfillment(of: [admitted], timeout: 5)
        cleanup.cancel()
        let root = testTempDirectory.appendingPathComponent(fixture.card.synchronizerAlias.description)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(fixture.storage.clearCallsCount, 0)
        await gate.open()
        let result = await XCTWaiter.fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(result, .completed)
        guard result == .completed else { return }
        try await cleanup.value
        XCTAssertEqual(fixture.storage.clearCallsCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let replacement = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        try await replacement.redeemer.cleanup()
    }

    func testIdleWipeWaitsForMempoolDatabaseWrite() async throws {
        try await assertIdleWipeWaitsForMempool(wipeFails: false)
    }

    func testIdleWipeWaitsForMempoolDatabaseWriteWhenStorageClearFails() async throws {
        try await assertIdleWipeWaitsForMempool(wipeFails: true)
    }

    func testWipeCompletesAfterCancellationThrow() async throws {
        try await assertWipeAfterActionError(CancellationError())
    }

    func testWipeCompletesAfterOrdinaryTerminalError() async throws {
        try await assertWipeAfterActionError(ZcashError.synchronizerNotPrepared)
    }

    func testConcurrentWipesCompleteEveryCallerOnce() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        let processor = fixture.synchronizer.blockProcessor
        let entered = XCTestExpectation(description: "wipe holds storage")
        let gate = GiftCardOperationGate()
        let events = CleanupEvents()
        fixture.storage.clearClosure = {
            if events.appendOnce("clear") { entered.fulfill() }
            await gate.wait()
        }
        let first = XCTestExpectation(description: "first wipe completed")
        let second = XCTestExpectation(description: "second wipe completed")
        let operation = Task {
            try await processor.wipe(context: AfterSyncHooksManager.WipeContext(prewipe: { events.append("pre1") }, completion: { _ in
                events.append("done1")
                first.fulfill()
            }))
        }
        await fulfillment(of: [entered], timeout: 5)
        let admitted = XCTestExpectation(description: "second wipe admitted")
        let secondOperation = Task {
            try await processor.wipe(context: AfterSyncHooksManager.WipeContext(prewipe: {
                events.append("pre2")
                admitted.fulfill()
            }, completion: { _ in
                events.append("done2")
                second.fulfill()
            }))
        }
        await fulfillment(of: [admitted], timeout: 5)
        XCTAssertEqual(fixture.storage.clearCallsCount, 1)
        await gate.open()
        await fulfillment(of: [first, second], timeout: 5)
        try await operation.value
        try await secondOperation.value
        XCTAssertEqual(events.events.filter { $0 == "done1" }.count, 1)
        XCTAssertEqual(events.events.filter { $0 == "done2" }.count, 1)
        try await fixture.redeemer.cleanup()
    }

    func testStartDuringWipeCannotCreateReplacementTasks() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        let processor = fixture.synchronizer.blockProcessor
        let entered = XCTestExpectation(description: "wipe entered")
        let finished = XCTestExpectation(description: "wipe finished")
        let gate = GiftCardOperationGate()
        let events = CleanupEvents()
        fixture.storage.clearClosure = {
            entered.fulfill()
            await gate.wait()
        }
        await processor.updateEventClosure(identifier: "route") { event in
            if case .startedSyncing = event {
                events.append("start")
                await processor.context.update(state: .txResubmission)
            }
        }
        let operation = Task {
            try await processor.wipe(context: AfterSyncHooksManager.WipeContext(prewipe: { }, completion: { _ in finished.fulfill() }))
        }
        await fulfillment(of: [entered], timeout: 5)
        await processor.start()
        let taskDuringWipe = await processor.syncTask
        XCTAssertNil(taskDuringWipe)
        await gate.open()
        await fulfillment(of: [finished], timeout: 5)
        try await operation.value
        let fresh = XCTestExpectation(description: "fresh start after wipe")
        await processor.updateEventClosure(identifier: "fresh") { event in
            if case .finished = event { fresh.fulfill() }
        }
        await processor.start()
        await fulfillment(of: [fresh], timeout: 5)
        fixture.storage.clearClosure = { }
        let cleanup = Task { try await fixture.redeemer.cleanup() }
        let cleanupFinished = XCTestExpectation(description: "final cleanup finished")
        Task { _ = try? await cleanup.value
            cleanupFinished.fulfill()
        }
        let result = await XCTWaiter.fulfillment(of: [cleanupFinished], timeout: 5)
        XCTAssertEqual(result, .completed)
        if result == .completed { try await cleanup.value }
    }

    func testCleanupWaitsForAlreadyAdmittedTimerServiceCall() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        _ = try await fixture.redeemer.check()
        let processor = fixture.synchronizer.blockProcessor
        let actionEntered = XCTestExpectation(description: "final action held")
        let pollEntered = XCTestExpectation(description: "real timer poll held")
        let stopped = XCTestExpectation(description: "sync owner stopped")
        let admitted = XCTestExpectation(description: "poll teardown admitted")
        let prematureWipe = XCTestExpectation(description: "wipe before poll returns")
        prematureWipe.isInverted = true
        let finished = XCTestExpectation(description: "cleanup terminal")
        let actionGate = GiftCardOperationGate()
        let pollGate = GiftCardOperationGate()
        let events = CleanupEvents()
        fixture.repository.findForResubmissionUpToClosure = { _ in
            actionEntered.fulfill()
            await actionGate.wait()
            return []
        }
        fixture.latest.updateBlockDataClosure = {
            pollEntered.fulfill()
            await pollGate.wait()
            events.append("poll:done")
        }
        fixture.storage.clearClosure = {
            if !events.events.contains("poll:done") { prematureWipe.fulfill() }
        }
        await routeToFinalAction(processor)
        await processor.updateEventClosure(identifier: "stopped") { event in
            if case .stopped = event { stopped.fulfill() }
        }
        await processor.start()
        await fulfillment(of: [actionEntered], timeout: 5)
        let existingTimer = await processor.backoffTimer
        let timer = try XCTUnwrap(existingTimer)
        timer.fire()
        await fulfillment(of: [pollEntered], timeout: 5)
        fixture.downloader.stopDownloadClosure = {
            if events.appendOnce("stop") { admitted.fulfill() }
        }
        let cleanup = Task {
            defer { finished.fulfill() }
            try await fixture.redeemer.cleanup()
        }
        await fulfillment(of: [admitted], timeout: 5)
        // The cancellation event is a positive owner checkpoint. The negative
        // window observes only whether wipe escapes the independently held poll.
        await actionGate.open()
        await fulfillment(of: [stopped], timeout: 5)
        await fulfillment(of: [prematureWipe], timeout: 0.1)
        await pollGate.open()
        await fulfillment(of: [finished], timeout: 5)
        try await cleanup.value
    }

    func testAwaitedStopCompletesQueuedRewindsAndSupersedesAutomaticRestart() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        let processor = fixture.synchronizer.blockProcessor
        let entered = XCTestExpectation(description: "action entered")
        let admitted = XCTestExpectation(description: "stop admitted")
        let rewound = XCTestExpectation(description: "all queued rewinds completed")
        rewound.expectedFulfillmentCount = 2
        let gate = GiftCardOperationGate()
        let events = CleanupEvents()
        fixture.repository.findForResubmissionUpToClosure = { _ in
            entered.fulfill()
            await gate.wait()
            return []
        }
        fixture.backend.rewindToHeightHeightClosure = { .success($0) }
        fixture.storage.rewindToClosure = { _ in }
        await processor.updateEventClosure(identifier: "route") { event in
            if case .startedSyncing = event {
                events.append("start")
                await processor.context.update(state: .txResubmission)
            }
        }
        await processor.start()
        await fulfillment(of: [entered], timeout: 5)
        await processor.start() // queues the preexisting automatic restart hook
        fixture.downloader.stopDownloadClosure = {
            if events.appendOnce("stop") { admitted.fulfill() }
        }
        let stop = Task { await processor.stopAndWait() }
        await fulfillment(of: [admitted], timeout: 5)
        for height in [3_000_000, 3_000_001] {
            try await processor.rewind(context: AfterSyncHooksManager.RewindContext(height: height, completion: { result in
                if case .failure = result { XCTFail("standalone drain should safely complete the rewind") }
                rewound.fulfill()
            }))
        }
        await gate.open()
        await stop.value
        await fulfillment(of: [rewound], timeout: 5)
        let taskAfterStop = await processor.syncTask
        XCTAssertNil(taskAfterStop)
        XCTAssertEqual(events.events.filter { $0 == "start" }.count, 1)
        fixture.repository.findForResubmissionUpToClosure = { _ in [] }
        await processor.start()
        let freshSync = await processor.syncTask
        _ = try await freshSync?.value
        XCTAssertEqual(events.events.filter { $0 == "start" }.count, 2)
        try await fixture.redeemer.cleanup()
    }

    func testWipeAdmittedFromOrdinaryTerminalErrorCallbackCompletes() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        let processor = fixture.synchronizer.blockProcessor
        let finished = XCTestExpectation(description: "wipe after terminal error")
        fixture.service.getInfoModeThrowableError = ZcashError.synchronizerNotPrepared
        await processor.updateEventClosure(identifier: "failed-wipe") { event in
            if case .failed = event {
                try? await processor.wipe(context: AfterSyncHooksManager.WipeContext(prewipe: { }, completion: { error in
                    XCTAssertNil(error)
                    finished.fulfill()
                }))
            }
        }
        await processor.start()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(fixture.storage.clearCallsCount, 1)
        try await fixture.redeemer.cleanup()
    }

    func testWipeKeepsAdmissionClosedUntilEveryTerminalCallbackReturns() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        let processor = fixture.synchronizer.blockProcessor
        let entered = XCTestExpectation(description: "first terminal callback held")
        let joined = XCTestExpectation(description: "second wipe joined")
        let secondDone = XCTestExpectation(description: "second callback completed")
        let gate = GiftCardOperationGate()
        try await processor.wipe(context: AfterSyncHooksManager.WipeContext(prewipe: { }, completion: { _ in
            entered.fulfill()
            await gate.wait()
        }))
        await fulfillment(of: [entered], timeout: 5)
        try await processor.wipe(context: AfterSyncHooksManager.WipeContext(prewipe: { joined.fulfill() }, completion: { _ in
            secondDone.fulfill()
        }))
        await fulfillment(of: [joined], timeout: 5)
        await processor.start()
        let held = await processor.syncTask
        XCTAssertNil(held)
        await gate.open()
        await fulfillment(of: [secondDone], timeout: 5)
        await processor.stopAndWait()
        XCTAssertEqual(fixture.storage.clearCallsCount, 1)
        try await fixture.redeemer.cleanup()
    }

    func testInternalRequestStopPreservesQueuedRestartWithoutJoiningItself() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        let processor = fixture.synchronizer.blockProcessor
        let entered = XCTestExpectation(description: "first action held")
        let restarted = XCTestExpectation(description: "queued internal restart admitted")
        let gate = GiftCardOperationGate()
        let events = CleanupEvents()
        fixture.repository.findForResubmissionUpToClosure = { _ in
            if events.appendOnce("action") {
                entered.fulfill()
                await gate.wait()
            }
            return []
        }
        await processor.updateEventClosure(identifier: "route") { event in
            if case .startedSyncing = event {
                events.append("start")
                if events.events.filter({ $0 == "start" }).count == 2 { restarted.fulfill() }
                await processor.context.update(state: .txResubmission)
            }
        }
        await processor.start()
        await fulfillment(of: [entered], timeout: 5)
        await processor.start()
        await processor.stop()
        await gate.open()
        let result = await XCTWaiter.fulfillment(of: [restarted], timeout: 5)
        XCTAssertEqual(result, .completed)
        try await fixture.redeemer.cleanup()
    }

    func testIdleBackendRewindIsJoinedBeforeCleanupCanWipeOrRemoveRoot() async throws {
        try await assertIdleRewindIsJoined(holdStorage: false)
    }

    func testIdleStorageRewindIsJoinedBeforeCleanupCanWipeOrRemoveRoot() async throws {
        try await assertIdleRewindIsJoined(holdStorage: true)
    }

    func testRewindQueuedByOrdinaryFailureCallbackCompletesWithoutAnotherOperation() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        let processor = fixture.synchronizer.blockProcessor
        let queued = XCTestExpectation(description: "ordinary failure queued rewind")
        let completed = XCTestExpectation(description: "queued rewind completed")
        let events = CleanupEvents()
        fixture.service.getInfoModeThrowableError = ZcashError.synchronizerNotPrepared
        fixture.backend.rewindToHeightHeightClosure = { .success($0) }
        fixture.storage.rewindToClosure = { _ in events.append("storage:rewind") }
        await processor.updateEventClosure(identifier: "failed-rewind") { event in
            if case .failed = event {
                try? await processor.rewind(context: AfterSyncHooksManager.RewindContext(height: 3_000_000, completion: { result in
                    if case .failure = result { XCTFail("queued rewind should complete successfully") }
                    events.append("completion")
                    completed.fulfill()
                }))
                queued.fulfill()
            }
        }
        await processor.start()
        await fulfillment(of: [queued], timeout: 5)
        let result = await XCTWaiter.fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(result, .completed)
        // Cleanup follows the bounded observation; it cannot supply the missing
        // completion that this regression requires from the ordinary-error exit.
        XCTAssertEqual(events.events, ["storage:rewind", "completion"])
        try await fixture.redeemer.cleanup()
    }

    func testPublicRewindDuringSuspendedOrdinaryFailureCallbackCompletesWithoutAnotherOperation() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        let processor = fixture.synchronizer.blockProcessor
        let failed = XCTestExpectation(description: "ordinary failure callback held")
        let completed = XCTestExpectation(description: "public rewind completed")
        let gate = GiftCardOperationGate()
        let events = CleanupEvents()
        fixture.service.getInfoModeThrowableError = ZcashError.synchronizerNotPrepared
        fixture.backend.rewindToHeightHeightClosure = { .success($0) }
        fixture.storage.rewindToClosure = { _ in events.append("storage:rewind") }
        await processor.updateEventClosure(identifier: "failed-held") { event in
            if case .failed = event {
                failed.fulfill()
                await gate.wait()
            }
        }
        await processor.start()
        await fulfillment(of: [failed], timeout: 5)
        let admitted = XCTestExpectation(description: "public rewind stop admitted")
        fixture.downloader.stopDownloadClosure = {
            if events.appendOnce("stop") { admitted.fulfill() }
        }
        let subscription = fixture.synchronizer.rewind(.height(blockheight: 3_000_000)).sink(receiveCompletion: { result in
            if case .failure = result { XCTFail("public rewind should succeed") }
            events.append("completion")
            completed.fulfill()
        }, receiveValue: { })
        // Ensure the public publisher task has actually queued its rewind before
        // releasing failure. Its request-only stop reaches the downloader seam.
        await fulfillment(of: [admitted], timeout: 5)
        await gate.open()
        let result = await XCTWaiter.fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(events.events.filter { $0 == "completion" }.count, 1)
        withExtendedLifetime(subscription) { }
        try await fixture.redeemer.cleanup()
    }

    func testRewindRacingWipeCannotAdmitWriterOrResetLaterStart() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        let processor = fixture.synchronizer.blockProcessor
        let entered = XCTestExpectation(description: "wipe holds storage")
        let wiped = XCTestExpectation(description: "wipe terminal")
        let rejected = XCTestExpectation(description: "racing rewind rejected")
        let gate = GiftCardOperationGate()
        let events = CleanupEvents()
        fixture.storage.clearClosure = {
            if events.appendOnce("clear") { entered.fulfill() }
            await gate.wait()
        }
        fixture.backend.rewindToHeightHeightClosure = { height in
            events.append("stale:backend")
            return .success(height)
        }
        fixture.storage.rewindToClosure = { _ in events.append("stale:storage") }
        try await processor.wipe(context: AfterSyncHooksManager.WipeContext(prewipe: { }, completion: { _ in wiped.fulfill() }))
        await fulfillment(of: [entered], timeout: 5)
        try await processor.rewind(context: AfterSyncHooksManager.RewindContext(height: 3_000_000, completion: { result in
            switch result {
            case .failure(let error): XCTAssertEqual(error as? ZcashError, .synchronizerNotPrepared)
            case .success: XCTFail("wipe must reject new rewind admission")
            }
            rejected.fulfill()
        }))
        await fulfillment(of: [rejected], timeout: 5)
        XCTAssertFalse(events.events.contains("stale:backend"))
        XCTAssertFalse(events.events.contains("stale:storage"))
        await gate.open()
        await fulfillment(of: [wiped], timeout: 5)
        await processor.stopAndWait()
        await routeToFinalAction(processor)
        await processor.start()
        let fresh = await processor.syncTask
        _ = try await fresh?.value
        let state = await processor.context.state
        XCTAssertEqual(state, .finished)
        XCTAssertFalse(events.events.contains("stale:backend"))
        XCTAssertFalse(events.events.contains("stale:storage"))
        fixture.storage.clearClosure = { }
        try await fixture.redeemer.cleanup()
    }

    private func assertIdleRewindIsJoined(holdStorage: Bool) async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        _ = try await fixture.redeemer.check()
        let processor = fixture.synchronizer.blockProcessor
        let entered = XCTestExpectation(description: "idle rewind writer held")
        let admitted = XCTestExpectation(description: "external drain admitted")
        let rewindFinished = XCTestExpectation(description: "rewind terminal")
        let stopFinished = XCTestExpectation(description: "external stop terminal")
        let cleanupFinished = XCTestExpectation(description: "cleanup terminal")
        let prematureStop = XCTestExpectation(description: "stop returned before writer released")
        prematureStop.isInverted = true
        let gate = GiftCardOperationGate()
        let events = CleanupEvents()
        fixture.backend.rewindToHeightHeightClosure = { height in
            events.append("backend:entered")
            if !holdStorage {
                entered.fulfill()
                await gate.wait()
            }
            events.append("backend:done")
            return .success(height)
        }
        fixture.storage.rewindToClosure = { _ in
            events.append("storage:entered")
            if holdStorage {
                entered.fulfill()
                await gate.wait()
            }
            events.append("writer:done")
        }
        fixture.repository.closeDBConnectionClosure = {
            XCTAssertTrue(events.events.contains("writer:done"))
            events.append("prewipe")
        }
        fixture.storage.clearClosure = {
            XCTAssertTrue(events.events.contains("writer:done"))
            events.append("clear")
        }
        let rewind = Task {
            try await processor.rewind(context: AfterSyncHooksManager.RewindContext(height: 3_000_000, completion: { result in
                if case .failure = result { XCTFail("already admitted rewind should complete safely") }
                events.append("rewind:done")
                rewindFinished.fulfill()
            }))
        }
        await fulfillment(of: [entered], timeout: 5)
        // Cancelling the public waiter must not remove the independently owned
        // rewind writer from the subsequent drain's ownership.
        rewind.cancel()
        fixture.downloader.stopDownloadClosure = {
            if events.appendOnce("stop") { admitted.fulfill() }
        }
        let stop = Task {
            await processor.stopAndWait()
            if !events.events.contains("released") { prematureStop.fulfill() }
            stopFinished.fulfill()
        }
        await fulfillment(of: [admitted], timeout: 5)
        let cleanup = Task {
            defer { cleanupFinished.fulfill() }
            try await fixture.redeemer.cleanup()
        }
        await fulfillment(of: [prematureStop], timeout: 0.1)
        XCTAssertFalse(events.events.contains("prewipe"))
        XCTAssertFalse(events.events.contains("clear"))
        let root = testTempDirectory.appendingPathComponent(fixture.card.synchronizerAlias.description)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        events.append("released")
        await gate.open()
        await fulfillment(of: [rewindFinished, stopFinished, cleanupFinished], timeout: 5)
        try await rewind.value
        await stop.value
        try await cleanup.value
        XCTAssertEqual(events.events.filter { $0 == "rewind:done" }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    private func assertIdleWipeWaitsForMempool(wipeFails: Bool) async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        _ = try await fixture.redeemer.check()
        let processor = fixture.synchronizer.blockProcessor
        let syncFinished = XCTestExpectation(description: "normal sync finished")
        let writerEntered = XCTestExpectation(description: "mempool writer entered")
        let stopped = XCTestExpectation(description: "teardown admitted")
        let cleanupFinished = XCTestExpectation(description: "cleanup terminal")
        let gate = GiftCardOperationGate()
        let events = CleanupEvents()
        var raw = RawTransaction()
        raw.data = Data([1])
        var mempool: AsyncThrowingStream<RawTransaction, Error>.Continuation!
        let stream = AsyncThrowingStream<RawTransaction, Error> { mempool = $0 }
        fixture.service.getMempoolStreamClosure = { stream }
        fixture.backend.decryptAndStoreTransactionTxBytesMinedHeightClosure = { _, _ in
            writerEntered.fulfill()
            await gate.wait()
            events.append("writer:done")
            return Data([2])
        }
        fixture.repository.findRawIDThrowableError = ZcashError.transactionRepositoryEntityNotFound
        await routeToFinalAction(processor)
        await processor.updateEventClosure(identifier: "finished") { event in
            if case .finished = event { syncFinished.fulfill() }
        }
        await processor.start()
        await fulfillment(of: [syncFinished], timeout: 5)
        let completedSync = await processor.syncTask
        _ = try await completedSync?.value
        let idleSync = await processor.syncTask
        XCTAssertNil(idleSync)
        mempool.yield(raw)
        await fulfillment(of: [writerEntered], timeout: 5)
        fixture.repository.closeDBConnectionClosure = { events.append("prewipe") }
        fixture.storage.clearClosure = {
            events.append("clear")
            XCTAssertTrue(events.events.contains("writer:done"))
            if wipeFails { throw ProcessorCleanupError.storage }
        }
        fixture.downloader.stopDownloadClosure = {
            if events.appendOnce("stop") { stopped.fulfill() }
        }
        let cleanup = Task {
            defer { cleanupFinished.fulfill() }
            try await fixture.redeemer.cleanup()
        }
        await fulfillment(of: [stopped], timeout: 5)
        let root = testTempDirectory.appendingPathComponent(fixture.card.synchronizerAlias.description)
        XCTAssertFalse(events.events.contains("prewipe"))
        XCTAssertFalse(events.events.contains("clear"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        await gate.open()
        let result = await XCTWaiter.fulfillment(of: [cleanupFinished], timeout: 5)
        XCTAssertEqual(result, .completed)
        guard result == .completed else { return }
        try await cleanup.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    private func assertWipeAfterActionError(_ error: Error) async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        let processor = fixture.synchronizer.blockProcessor
        let entered = XCTestExpectation(description: "backend action entered")
        let stopped = XCTestExpectation(description: "wipe requested stop")
        let finished = XCTestExpectation(description: "wipe terminal")
        let gate = GiftCardOperationGate()
        let events = CleanupEvents()
        fixture.service.getInfoModeClosure = { _ in
            entered.fulfill()
            await gate.wait()
            throw error
        }
        await processor.start()
        await fulfillment(of: [entered], timeout: 5)
        fixture.downloader.stopDownloadClosure = { if events.appendOnce("stop") { stopped.fulfill() } }
        let operation = Task {
            try await processor.wipe(context: AfterSyncHooksManager.WipeContext(prewipe: { }, completion: { _ in finished.fulfill() }))
        }
        await fulfillment(of: [stopped], timeout: 5)
        await gate.open()
        let result = await XCTWaiter.fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(result, .completed)
        guard result == .completed else { return }
        try await operation.value
        XCTAssertEqual(fixture.service.getInfoModeCallsCount, 1, "cancellation must win over service retry")
        XCTAssertEqual(fixture.service.closeConnectionsCallsCount, 0, "cancelled service errors must not reset connections for retries")
        try await fixture.redeemer.cleanup()
    }

    private func routeToFinalAction(_ processor: CompactBlockProcessor) async {
        await processor.updateEventClosure(identifier: "route") { event in
            if case .startedSyncing = event { await processor.context.update(state: .txResubmission) }
        }
    }
}

private enum ProcessorCleanupError: Error { case storage }

final class CleanupEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var events: [String] { lock.withLock { values } }
    func append(_ value: String) { lock.withLock { values.append(value) } }
    @discardableResult func appendOnce(_ value: String) -> Bool {
        lock.withLock {
            guard !values.contains(value) else { return false }
            values.append(value)
            return true
        }
    }
}
