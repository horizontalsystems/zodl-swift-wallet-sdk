import Combine
import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class GiftCardCleanupTests: ZcashTestCase {
    func testCancelledCleanupRetainsOwnershipUntilSuccessfulWipeCompletes() async throws {
        try await assertCleanupRetainsOwnership(wipeFails: false)
    }

    func testCancelledCleanupRetainsOwnershipUntilFailedWipeCompletes() async throws {
        try await assertCleanupRetainsOwnership(wipeFails: true)
    }

    func testRepeatedCleanupAndOldDeinitPreserveReplacementWallet() async throws {
        var fixture: GiftCardCancellationFixture? = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        let card = try XCTUnwrap(fixture).card
        _ = try await fixture?.redeemer.check()
        let storage = try XCTUnwrap(fixture).storage
        let firstFinished = XCTestExpectation(description: "first cleanup completed")
        let first = Task {
            defer { firstFinished.fulfill() }
            try await fixture?.redeemer.cleanup()
        }
        try await waitFor(firstFinished)
        try await first.value
        XCTAssertEqual(storage.clearCallsCount, 1)
        let replacement = try makeReplacement(card: card)
        let marker = try writeMarker(card: card, name: "replacement-marker")
        let repeatedFinished = XCTestExpectation(description: "repeated cleanup completed")
        let repeated = Task {
            defer { repeatedFinished.fulfill() }
            try await fixture?.redeemer.cleanup()
        }
        try await waitFor(repeatedFinished)
        try await repeated.value
        XCTAssertEqual(storage.clearCallsCount, 1)
        weak var old = fixture?.redeemer
        fixture = nil
        XCTAssertNil(old)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        assertAlreadyActive(card: card)
        withExtendedLifetime(replacement) { }
    }

    func testDirectoryDeletionErrorPropagatesAfterWipeFailure() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        _ = try await fixture.redeemer.check()
        _ = try writeMarker(card: fixture.card, name: "undeletable-marker")
        fixture.storage.clearClosure = { throw CleanupTestError.wipeFailed }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: testTempDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: testTempDirectory.path) }
        let finished = XCTestExpectation(description: "directory error returned")
        let cleanup = Task {
            defer { finished.fulfill() }
            try await fixture.redeemer.cleanup()
        }
        try await waitFor(finished)
        do {
            try await cleanup.value
            XCTFail("Directory deletion failure must be returned")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
        }
        let replacement = try makeReplacement(card: fixture.card)
        withExtendedLifetime(replacement) { }
    }

    func testCleanupWithEarlyWipeValidationFailureWaitsForWriter() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        _ = try await fixture.redeemer.check()
        let marker = try writeMarker(card: fixture.card, name: "held-writer")
        let entered = XCTestExpectation(description: "writer entered")
        let admitted = XCTestExpectation(description: "cleanup drain admitted")
        let finished = XCTestExpectation(description: "cleanup after early wipe error")
        let gate = GiftCardOperationGate()
        let events = CleanupEvents()
        fixture.service.getInfoModeClosure = { _ in
            entered.fulfill()
            await gate.wait()
            events.append("writer:done")
            throw ZcashError.synchronizerNotPrepared
        }
        await fixture.synchronizer.blockProcessor.start()
        await fulfillment(of: [entered], timeout: 5)
        fixture.synchronizer.initializer.urlsParsingError = ZcashError.synchronizerNotPrepared
        await fixture.synchronizer.updateStatus(.stopped)
        fixture.downloader.stopDownloadClosure = {
            if events.appendOnce("stop") { admitted.fulfill() }
        }
        let cleanup = Task {
            defer { finished.fulfill() }
            try await fixture.redeemer.cleanup()
        }
        await fulfillment(of: [admitted], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(fixture.storage.clearCallsCount, 0)
        assertAlreadyActive(card: fixture.card)
        await gate.open()
        try await waitFor(finished)
        try await cleanup.value
        XCTAssertTrue(events.events.contains("writer:done"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCleanupClosesServiceAndRootBeforeRemovingDirectory() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        _ = try await fixture.redeemer.check()
        let marker = try writeMarker(card: fixture.card, name: "tor-writer")
        let events = CleanupEvents()
        let closed = XCTestExpectation(description: "service connections closed")
        let free = XCTestExpectation(description: "native root freed")
        let gate = GiftCardOperationGate()
        fixture.service.closeConnectionsClosure = {
            XCTAssertEqual(fixture.storage.clearCallsCount, 1)
            events.append("service:entered")
            closed.fulfill()
            await gate.wait()
            events.append("service:done")
        }
        var native = TorHTTPGetNative()
        native.createRuntime = { _, _ in
            XCTFail("Cleanup must not bootstrap Tor")
            return nil
        }
        native.freeRuntime = { _ in
            XCTAssertTrue(events.events.contains("service:done"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
            events.append("runtime:free")
            free.fulfill()
        }
        let tor = TorClient(runtimePtr: OpaquePointer(bitPattern: 1)!, torDir: marker.deletingLastPathComponent(), httpGetNative: native)
        fixture.container.mock(type: TorClient.self, isSingleton: true) { _ in tor }
        let finished = XCTestExpectation(description: "cleanup completed")
        let cleanup = Task {
            defer { finished.fulfill() }
            try await fixture.redeemer.cleanup()
        }
        await fulfillment(of: [closed], timeout: 5)
        XCTAssertFalse(events.events.contains("runtime:free"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        await gate.open()
        try await waitFor(finished)
        try await cleanup.value
        await fulfillment(of: [free], timeout: 5)
        try await fixture.redeemer.cleanup()
        XCTAssertEqual(events.events.filter { $0 == "runtime:free" }.count, 1)
    }

    func testCleanupDisposesActualCachedTorConnectionsBeforeFinalRuntimeAndRootRemoval() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        _ = try await fixture.redeemer.check()
        let marker = try writeMarker(card: fixture.card, name: "cached-tor-owner")
        let events = CleanupEvents()
        let wipeEntered = XCTestExpectation(description: "wipe entered")
        let gate = GiftCardOperationGate()
        fixture.storage.clearClosure = {
            wipeEntered.fulfill()
            await gate.wait()
            events.append("wipe:done")
        }
        var native = TorHTTPGetNative()
        native.createRuntime = { _, _ in
            XCTFail("Cleanup must never create a native runtime")
            return nil
        }
        native.connectLightwalletd = { _, _ in
            events.append("connect")
            return OpaquePointer(bitPattern: 2)
        }
        native.freeLightwalletd = { _ in
            XCTAssertTrue(events.events.contains("wipe:done"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
            events.append("lwd:free")
        }
        native.freeRuntime = { _ in
            XCTAssertEqual(events.events.filter { $0 == "lwd:free" }.count, 2)
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
            events.append("runtime:free")
        }
        let tor = TorClient(runtimePtr: OpaquePointer(bitPattern: 1)!, torDir: marker.deletingLastPathComponent(), httpGetNative: native)
        fixture.container.mock(type: TorClient.self, isSingleton: true) { _ in tor }
        let service = LightWalletGRPCServiceOverTor(endpoint: LightWalletEndpointBuilder.default, tor: tor)
        fixture.synchronizer.initializer.lightWalletService = service
        _ = try await service.serviceConnections.connectToLightwalletd(.defaultTor)
        _ = try await service.serviceConnections.connectToLightwalletd(.torInGroup("card-test"))
        let finished = XCTestExpectation(description: "cleanup completed")
        let cleanup = Task {
            defer { finished.fulfill() }
            try await fixture.redeemer.cleanup()
        }
        await fulfillment(of: [wipeEntered], timeout: 5)
        cleanup.cancel()
        XCTAssertEqual(events.events, ["connect", "connect"])
        assertAlreadyActive(card: fixture.card)
        await gate.open()
        try await waitFor(finished)
        try await cleanup.value
        XCTAssertEqual(events.events, ["connect", "connect", "wipe:done", "lwd:free", "lwd:free", "runtime:free"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let replacement = try makeReplacement(card: fixture.card)
        let replacementMarker = try writeMarker(card: fixture.card, name: "replacement-after-tor")
        try await fixture.redeemer.cleanup()
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacementMarker.path))
        XCTAssertEqual(events.events.filter { $0 == "runtime:free" }.count, 1)
        withExtendedLifetime(replacement) { }
    }

    func testCleanupBeforeCheckDoesNotBootstrapTor() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        let events = CleanupEvents()
        var native = TorHTTPGetNative()
        native.createRuntime = { _, _ in
            events.append("create")
            return nil
        }
        native.freeRuntime = { _ in events.append("free") }
        let tor = TorClient(torDir: testTempDirectory.appendingPathComponent("unused-tor"), httpGetNative: native)
        fixture.container.mock(type: TorClient.self, isSingleton: true) { _ in tor }
        try await fixture.redeemer.cleanup()
        XCTAssertTrue(events.events.isEmpty)
    }

    func testBridgeObservesSuccessCompletedBeforeSubscription() async throws {
        let subject = PassthroughSubject<Void, Error>()
        subject.send(completion: .finished)
        let finished = XCTestExpectation(description: "already completed publisher observed")
        let task = Task {
            defer { finished.fulfill() }
            try await GiftCardRedeemer.awaitCompletion(of: subject.eraseToAnyPublisher())
        }
        try await waitFor(finished)
        try await task.value
    }

    func testBridgeObservesFailureCompletedBeforeSubscription() async throws {
        let subject = PassthroughSubject<Void, Error>()
        subject.send(completion: .failure(CleanupTestError.wipeFailed))
        let finished = XCTestExpectation(description: "already failed publisher observed")
        let task = Task {
            defer { finished.fulfill() }
            try await GiftCardRedeemer.awaitCompletion(of: subject.eraseToAnyPublisher())
        }
        try await waitFor(finished)
        do {
            try await task.value
            XCTFail("The bridge must preserve terminal failure")
        } catch {
            XCTAssertEqual(error as? CleanupTestError, .wipeFailed)
        }
    }

    private func assertCleanupRetainsOwnership(wipeFails: Bool) async throws {
        var fixture: GiftCardCancellationFixture? = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        let card = try XCTUnwrap(fixture).card
        _ = try await fixture?.redeemer.check()
        let marker = try writeMarker(card: card, name: "live-marker")
        let wipeEntered = XCTestExpectation(description: "real wipe reached storage")
        let gate = GiftCardOperationGate()
        fixture?.storage.clearClosure = {
            wipeEntered.fulfill()
            await gate.wait()
            if wipeFails { throw CleanupTestError.wipeFailed }
        }
        let finished = XCTestExpectation(description: "cleanup returned after wipe")
        let completion = CleanupCompletionProbe()
        weak var old = fixture?.redeemer
        let cleanup = startCleanup(try XCTUnwrap(fixture).redeemer, completion: completion, finished: finished)
        // Always release the controlled dependency, even if an ordering assertion fails.
        let entered = await XCTWaiter.fulfillment(of: [wipeEntered], timeout: 5)
        cleanup.cancel()
        fixture = nil
        XCTAssertEqual(entered, .completed)
        XCTAssertNotNil(old)
        XCTAssertFalse(completion.isFinished)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        assertAlreadyActive(card: card)
        XCTAssertEqual(try GiftCardRedeemer.removeLeftoverWallets(in: testTempDirectory), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        await gate.open()
        try await waitFor(finished)
        try await cleanup.value
        XCTAssertTrue(completion.isFinished)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.deletingLastPathComponent().path))
        let replacement = try makeReplacement(card: card)
        let replacementMarker = try writeMarker(card: card, name: "replacement-marker")
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacementMarker.path))
        assertAlreadyActive(card: card)
        withExtendedLifetime(replacement) { }
    }

    private func startCleanup(
        _ redeemer: GiftCardRedeemer,
        completion: CleanupCompletionProbe,
        finished: XCTestExpectation
    ) -> Task<Void, Error> {
        Task {
            defer {
                completion.finish()
                finished.fulfill()
            }
            try await redeemer.cleanup()
        }
    }

    private func assertAlreadyActive(card: GiftCard) {
        XCTAssertThrowsError(try makeReplacement(card: card)) { error in
            XCTAssertEqual(error as? ZcashError, .giftCardRedeemerAlreadyActive)
        }
    }

    private func makeReplacement(card: GiftCard) throws -> GiftCardRedeemer {
        try GiftCardRedeemer(
            card: card,
            network: ZcashNetworkBuilder.network(for: .testnet),
            endpoint: LightWalletEndpointBuilder.default,
            isTorEnabled: false,
            storageDirectory: testTempDirectory,
            loggingPolicy: .noLogging
        )
    }

    private func writeMarker(card: GiftCard, name: String) throws -> URL {
        let root = testTempDirectory.appendingPathComponent(card.synchronizerAlias.description)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent(name)
        try Data([1]).write(to: marker)
        return marker
    }

    private func waitFor(_ expectation: XCTestExpectation) async throws {
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 5)
        XCTAssertEqual(result, .completed)
        guard result == .completed else { throw CleanupTestError.timedOut }
    }
}

private enum CleanupTestError: Error {
    case wipeFailed
    case timedOut
}

private final class CleanupCompletionProbe {
    private let lock = NSLock()
    private var finished = false

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
    }
}
