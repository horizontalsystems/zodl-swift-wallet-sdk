import Foundation
@testable import TestUtils
@testable import ZcashLightClientKit

/// Keeps the native restore boundary offline while exercising real Slipstream preparation.
actor GiftCardAnchorCapture {
    struct Call {
        let isRestore: Bool
        let birthday: BlockHeight
        let fallbackCheckpointHeight: BlockHeight
        let endpoint: LightWalletEndpoint
        let network: ZcashNetwork
        let torDirPath: String?
    }

    private(set) var calls: [Call] = []
    private var response: SlipstreamRestoreAnchor?

    func setResponse(_ response: SlipstreamRestoreAnchor?) {
        self.response = response
    }

    func resolve(
        isRestore: Bool,
        birthday: BlockHeight,
        fallbackCheckpointHeight: BlockHeight,
        endpoint: LightWalletEndpoint,
        network: ZcashNetwork,
        torDirPath: String?
    ) -> SlipstreamRestoreAnchor? {
        calls.append(Call(
            isRestore: isRestore,
            birthday: birthday,
            fallbackCheckpointHeight: fallbackCheckpointHeight,
            endpoint: endpoint,
            network: network,
            torDirPath: torDirPath
        ))
        return response
    }
}

private actor GiftCardFixtureAccountState {
    let account: Account
    private var created = false

    init(account: Account) {
        self.account = account
    }

    func markCreated() {
        created = true
    }

    func accounts() -> [Account] {
        created ? [account] : []
    }
}

struct GiftCardSlipstreamFixture {
    let card: GiftCard
    let synchronizer: SlipstreamSynchronizer
    let initializer: Initializer
    let engine: GatedFakeSlipstreamEngine
    let backend: ZcashRustBackendWeldingMock
    let service: LightWalletServiceMock
    let repository: TransactionRepositoryMock
    let anchor: GiftCardAnchorCapture
    let storageRoot: URL
    let torDirectory: URL
    let account: Account
    let balance: AccountBalance

    static func make(storageDirectory: URL, isTorEnabled: Bool) async throws -> GiftCardSlipstreamFixture {
        let root = storageDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let torDirectory = root.appendingPathComponent("tor", isDirectory: true)
        let card = try GiftCard(link: GiftCardTests.zodlTestnetLink)
        let network = ZcashNetworkBuilder.network(for: .testnet)
        let endpoint = LightWalletEndpoint(address: "127.0.0.1", port: 1, secure: false)
        let account = Account(
            id: TestsData.mockedAccountUUID,
            name: "Gift card",
            keySource: nil,
            seedFingerprint: nil,
            hdAccountIndex: nil,
            ufvk: nil,
            uivk: nil
        )
        let balance = AccountBalance(
            saplingBalance: .zero,
            orchardBalance: PoolBalance(
                spendableValue: Zatoshi(50_000),
                changePendingConfirmation: .zero,
                valuePendingSpendability: .zero
            ),
            unshielded: .zero
        )
        let summary = WalletSummary(
            accountBalances: [account.id: balance],
            chainTipHeight: 3_000_010,
            fullyScannedHeight: 3_000_010,
            recoveryProgress: nil,
            scanProgress: nil,
            nextSaplingSubtreeIndex: 0,
            nextOrchardSubtreeIndex: 0,
            nextIronwoodSubtreeIndex: 0
        )
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 0, chainTip: 3_000_010))
        await engine.setNextWalletSummary(summary)

        let accountState = GiftCardFixtureAccountState(account: account)
        let backend = ZcashRustBackendWeldingMock()
        backend.initDataDbSeedReturnValue = DbInitResult.success
        backend.listAccountsClosure = { await accountState.accounts() }
        backend.createAccountSeedTreeStateRecoverUntilNameKeySourceClosure = { _, _, _, _, _ in
            await accountState.markCreated()
            return UnifiedSpendingKey(network: network.networkType, bytes: [])
        }
        let service = LightWalletServiceMock()
        let repository = TransactionRepositoryMock()
        repository.closeDBConnectionClosure = {}
        let storage = CompactBlockRepositoryMock()
        storage.createClosure = {}
        storage.clearClosure = {}
        let container = DIContainer()
        container.isTestEnvironment = true
        container.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in backend }
        container.mock(type: LightWalletService.self, isSingleton: true) { _ in service }
        container.mock(type: TransactionRepository.self, isSingleton: true) { _ in repository }
        container.mock(type: CompactBlockRepository.self, isSingleton: true) { _ in storage }

        let initializer = Initializer(
            container: container,
            cacheDbURL: nil,
            fsBlockDbRoot: root.appendingPathComponent("blocks", isDirectory: true),
            generalStorageURL: root.appendingPathComponent("general", isDirectory: true),
            dataDbURL: root.appendingPathComponent("data.db"),
            torDirURL: torDirectory,
            endpoint: endpoint,
            network: network,
            spendParamsURL: root.appendingPathComponent("sapling-spend.params"),
            outputParamsURL: root.appendingPathComponent("sapling-output.params"),
            saplingParamsSourceURL: SaplingParamsSourceURL.tests,
            loggingPolicy: .noLogging,
            isTorEnabled: isTorEnabled,
            isExchangeRateEnabled: false
        )
        let anchor = GiftCardAnchorCapture()
        let synchronizer = SlipstreamSynchronizer(
            initializer: initializer,
            alternateEndpoints: [],
            engine: engine,
            restoreAnchor: { isRestore, birthday, fallbackCheckpoint, endpoint, network, torDirPath in
                await anchor.resolve(
                    isRestore: isRestore,
                    birthday: birthday,
                    fallbackCheckpointHeight: fallbackCheckpoint,
                    endpoint: endpoint,
                    network: network,
                    torDirPath: torDirPath
                )
            }
        )
        return GiftCardSlipstreamFixture(
            card: card,
            synchronizer: synchronizer,
            initializer: initializer,
            engine: engine,
            backend: backend,
            service: service,
            repository: repository,
            anchor: anchor,
            storageRoot: root,
            torDirectory: torDirectory,
            account: account,
            balance: balance
        )
    }
}
