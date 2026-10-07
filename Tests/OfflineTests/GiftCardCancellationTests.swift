import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class GiftCardCancellationTests: ZcashTestCase {
    func testUncancelledRedemptionCreatesAndSubmits() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        _ = try await fixture.redeemer.check()
        let result = try await fixture.redeemer.redeem(to: fixture.card.fundingAddress, memo: nil, recordIn: nil)
        XCTAssertEqual(result.results, [.success(txId: Data(repeating: 0xA1, count: 32))])
        XCTAssertEqual(fixture.encoder.createdTransactions.count, 1)
        XCTAssertEqual(fixture.encoder.submittedTransactions.count, 1)
        try await fixture.redeemer.cleanup()
    }

    func testCancelledQueuedRedemptionDoesNotCreateOrSubmit() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        _ = try await fixture.redeemer.check()
        let predecessorEntered = XCTestExpectation(description: "preceding check proposes fee")
        let gate = GiftCardOperationGate()
        fixture.encoder.propose = {
            predecessorEntered.fulfill()
            await gate.wait()
            return FfiProposalFixtures.makeProposal(steps: [])
        }
        let predecessor = Task { try await fixture.redeemer.check() }
        await fulfillment(of: [predecessorEntered], timeout: 5)

        let redemptionEntered = XCTestExpectation(description: "redemption entered redeemer actor")
        let redemptionFinished = XCTestExpectation(description: "cancelled queued redemption finished")
        let redemption = Task {
            defer { redemptionFinished.fulfill() }
            return try await fixture.redeemer.redeemForCancellationTest(to: fixture.card.fundingAddress, entered: redemptionEntered)
        }
        await fulfillment(of: [redemptionEntered], timeout: 5)
        // The helper stays on this actor until redeem suspends in serialized. This barrier
        // cannot execute before the redemption has joined the queue behind the held check.
        _ = await fixture.redeemer.cardWalletConfirmationsPolicy()
        redemption.cancel()
        fixture.encoder.propose = {
            XCTFail("Cancelled queued redemption must not prepare a proposal")
            return FfiProposalFixtures.makeProposal(steps: [])
        }
        await gate.open()
        _ = try await predecessor.value
        await fulfillment(of: [redemptionFinished], timeout: 5)
        await assertCancellation(redemption)
        fixture.encoder.propose = nil

        XCTAssertEqual(fixture.encoder.createdTransactions.count, 0)
        XCTAssertEqual(fixture.encoder.submittedTransactions.count, 0)
        let following = try await fixture.redeemer.check()
        XCTAssertEqual(following.state, .ready, "a cancelled operation must not poison the queue")
        try await fixture.redeemer.cleanup()
    }

    func testCancellationDuringPreparationDoesNotCreate() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        _ = try await fixture.redeemer.check()
        let proposalEntered = XCTestExpectation(description: "redemption preparing proposal")
        let gate = GiftCardOperationGate()
        fixture.encoder.propose = {
            proposalEntered.fulfill()
            await gate.wait()
            return FfiProposalFixtures.makeProposal(steps: [])
        }
        let finished = XCTestExpectation(description: "cancelled preparation finished")
        let redemption = Task {
            defer { finished.fulfill() }
            return try await fixture.redeemer.redeem(to: fixture.card.fundingAddress, memo: nil, recordIn: nil)
        }
        await fulfillment(of: [proposalEntered], timeout: 5)
        redemption.cancel()
        fixture.encoder.propose = nil
        await gate.open()
        await fulfillment(of: [finished], timeout: 5)
        await assertCancellation(redemption)

        XCTAssertEqual(fixture.encoder.createdTransactions.count, 0)
        XCTAssertEqual(fixture.encoder.submittedTransactions.count, 0)
        let following = try await fixture.redeemer.check()
        XCTAssertEqual(following.state, .ready)
        try await fixture.redeemer.cleanup()
    }

    func testCancelledCallerStillRunsCleanup() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        _ = try await fixture.redeemer.check()
        let root = testTempDirectory.appendingPathComponent(fixture.card.synchronizerAlias.description)
        let marker = root.appendingPathComponent("cleanup-marker")
        try Data([1]).write(to: marker)
        let predecessorEntered = XCTestExpectation(description: "check before cleanup")
        let gate = GiftCardOperationGate()
        fixture.encoder.propose = {
            predecessorEntered.fulfill()
            await gate.wait()
            return FfiProposalFixtures.makeProposal(steps: [])
        }
        let predecessor = Task { try await fixture.redeemer.check() }
        await fulfillment(of: [predecessorEntered], timeout: 5)
        let cleanupEntered = XCTestExpectation(description: "cleanup entered redeemer actor")
        let cleanupFinished = XCTestExpectation(description: "cancelled caller cleanup finished")
        let cleanup = Task {
            defer { cleanupFinished.fulfill() }
            try await fixture.redeemer.cleanupForCancellationTest(entered: cleanupEntered)
        }
        await fulfillment(of: [cleanupEntered], timeout: 5)
        _ = await fixture.redeemer.cardWalletConfirmationsPolicy()
        cleanup.cancel()
        fixture.encoder.propose = nil
        await gate.open()
        _ = try await predecessor.value
        await fulfillment(of: [cleanupFinished], timeout: 5)
        try await cleanup.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(fixture.storage.clearCallsCount, 1)
        let replacement = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        try await replacement.redeemer.cleanup()
    }

    private func assertCancellation(_ task: Task<GiftCardRedeemer.Redemption, Error>) async {
        do {
            _ = try await task.value
            XCTFail("Cancelled redemption must throw before creating a claim")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error.localizedDescription)")
        }
    }
}

// Test helpers stay outside the SDK. There is no suspension between the signal and the
// public call, so a subsequent redeemer actor barrier proves admission to serialized.
private extension GiftCardRedeemer {
    func redeemForCancellationTest(to recipient: UnifiedAddress, entered: XCTestExpectation) async throws -> Redemption {
        entered.fulfill()
        return try await redeem(to: recipient, memo: nil, recordIn: nil)
    }

    func cleanupForCancellationTest(entered: XCTestExpectation) async throws {
        entered.fulfill()
        try await cleanup()
    }
}

actor GiftCardOperationGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in continuations { continuation.resume() }
        continuations.removeAll()
    }
}

struct GiftCardCancellationFixture {
    let card: GiftCard
    let redeemer: GiftCardRedeemer
    let synchronizer: SDKSynchronizer
    let encoder: GiftCardCancellationEncoder
    let storage: CompactBlockRepositoryMock
    let backend: ZcashRustBackendWeldingMock
    let repository: TransactionRepositoryMock
    let service: LightWalletServiceMock
    let downloader: BlockDownloaderMock
    let container: DIContainer
    let latest: LatestBlocksDataProviderMock

    static func make(storageDirectory: URL) async throws -> GiftCardCancellationFixture {
        let card = try GiftCard(link: GiftCardTests.zodlTestnetLink)
        let container = DIContainer()
        container.isTestEnvironment = true
        let backend = ZcashRustBackendWeldingMock()
        let account = Account(
            id: TestsData.mockedAccountUUID,
            name: "Gift card",
            keySource: nil,
            seedFingerprint: nil,
            hdAccountIndex: nil,
            ufvk: nil,
            uivk: nil
        )
        backend.listAccountsReturnValue = [account]
        let balance = AccountBalance(
            saplingBalance: .zero,
            orchardBalance: PoolBalance(spendableValue: Zatoshi(50_000), changePendingConfirmation: .zero, valuePendingSpendability: .zero),
            unshielded: .zero
        )
        backend.getWalletSummaryReturnValue = WalletSummary(
            accountBalances: [account.id: balance],
            chainTipHeight: 3_000_010,
            fullyScannedHeight: 3_000_010,
            recoveryProgress: nil,
            scanProgress: nil,
            nextSaplingSubtreeIndex: 0,
            nextOrchardSubtreeIndex: 0,
            nextIronwoodSubtreeIndex: 0
        )
        let service = LightWalletServiceMock()
        service.getTreeStateModeThrowableError = LightWalletServiceError.timeOut
        service.getMempoolStreamClosure = { AsyncThrowingStream { $0.finish() } }
        service.closeConnectionsClosure = { }
        let repository = TransactionRepositoryMock()
        repository.closeDBConnectionClosure = { }
        repository.findForResubmissionUpToReturnValue = []
        let storage = CompactBlockRepositoryMock()
        storage.clearClosure = { }
        let latest = LatestBlocksDataProviderMock()
        latest.underlyingLatestBlockHeight = 3_000_010
        latest.underlyingFullyScannedHeight = 3_000_010
        latest.underlyingMaxScannedHeight = 3_000_010
        latest.underlyingWalletBirthday = 3_000_000
        latest.resetClosure = { }
        latest.updateScannedDataClosure = { }
        latest.updateBlockDataClosure = { }
        container.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in backend }
        container.mock(type: LightWalletService.self, isSingleton: true) { _ in service }
        container.mock(type: TransactionRepository.self, isSingleton: true) { _ in repository }
        container.mock(type: CompactBlockRepository.self, isSingleton: true) { _ in storage }
        container.mock(type: LatestBlocksDataProvider.self, isSingleton: true) { _ in latest }
        let downloader = BlockDownloaderMock()
        downloader.stopDownloadClosure = { }
        downloader.rewindLatestDownloadedBlockHeightClosure = { _ in }
        container.mock(type: BlockDownloader.self, isSingleton: true) { _ in downloader }
        let encoder = GiftCardCancellationEncoder()
        var synchronizer: SDKSynchronizer!
        let redeemer = try GiftCardRedeemer(
            card: card,
            network: ZcashNetworkBuilder.network(for: .testnet),
            endpoint: LightWalletEndpointBuilder.default,
            isTorEnabled: false,
            storageDirectory: storageDirectory,
            loggingPolicy: .noLogging,
            container: container,
            makeSynchronizer: { initializer in
                let processor = CompactBlockProcessor(initializer: initializer, walletBirthdayProvider: { initializer.walletBirthday })
                synchronizer = SDKSynchronizer(
                    status: .stopped,
                    initializer: initializer,
                    transactionEncoder: encoder,
                    transactionRepository: repository,
                    blockProcessor: processor,
                    syncSessionTicker: .live
                )
                return synchronizer
            }
        )
        await synchronizer.updateStatus(.synced)
        return GiftCardCancellationFixture(
            card: card, redeemer: redeemer, synchronizer: synchronizer, encoder: encoder, storage: storage,
            backend: backend, repository: repository, service: service, downloader: downloader, container: container, latest: latest
        )
    }
}

/// Replaces proving/network work while keeping the redeemer, synchronizer and broadcaster real.
final class GiftCardCancellationEncoder: TransactionEncoder {
    var propose: (() async throws -> Proposal)?
    private(set) var createdTransactions: [CreatedTransaction] = []
    private(set) var submittedTransactions: [EncodedTransaction] = []

    func proposeSendMax(accountUUID: AccountUUID, recipient: String, memoBytes: MemoBytes?, mode: MaxSpendMode) async throws -> Proposal {
        if let propose { return try await propose() }
        return FfiProposalFixtures.makeProposal(steps: [])
    }

    func requiresSaplingParameters(for proposal: Proposal) throws -> Bool { false }

    func createProposedTransactions(proposal: Proposal, spendingKey: UnifiedSpendingKey, ovkPolicy: OvkPolicy) async throws -> [CreatedTransaction] {
        let transaction = CreatedTransaction(txId: Data(repeating: 0xA1, count: 32), raw: Data([1]), expiryHeight: 3_000_100)
        createdTransactions.append(transaction)
        return [transaction]
    }

    func submit(transaction: EncodedTransaction) async throws {
        submittedTransactions.append(transaction)
    }

    func fetchTransactionsForTxIds(_ txIds: [Data]) async throws -> [ZcashTransaction.Overview] { [] }
    func closeDBConnection() { }
    func isTransactionKnownToServer(txId: Data) async -> Bool { false }
    func createdTransactions(forTxIds txIds: [Data]) async throws -> [CreatedTransaction] { createdTransactions }
    func proposeTransfer(accountUUID: AccountUUID, recipient: String, amount: Zatoshi, memoBytes: MemoBytes?) async throws -> Proposal {
        throw ZcashError.giftCardNothingToRedeem
    }
    func proposeOrchardToIronwoodMigration(accountUUID: AccountUUID) async throws -> Proposal {
        throw ZcashError.giftCardNothingToRedeem
    }
    func proposeShielding(accountUUID: AccountUUID, shieldingThreshold: Zatoshi, memoBytes: MemoBytes?, transparentReceiver: String?) async throws -> Proposal? {
        throw ZcashError.giftCardNothingToRedeem
    }
    func proposeFulfillingPaymentFromURI(_ uri: String, accountUUID: AccountUUID) async throws -> Proposal {
        throw ZcashError.giftCardNothingToRedeem
    }
}
