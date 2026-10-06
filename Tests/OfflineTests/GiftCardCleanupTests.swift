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
