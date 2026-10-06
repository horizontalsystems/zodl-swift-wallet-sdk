//
//  GiftCardRedeemer.swift
//  ZcashLightClientKit
//

import Combine
import Foundation

/// What ``GiftCardRedeemer/check()`` found on chain for a gift card.
public struct GiftCardStatus: Equatable {
    /// What the card can do right now.
    public enum State: Equatable {
        /// The card has funds that can be redeemed now: ``GiftCardStatus/spendable`` is more than
        /// the fee of the transaction that sweeps it.
        case ready
        /// The card has funds, but not enough of them are spendable yet: they are waiting for
        /// confirmations.
        ///
        /// Card funds come from another wallet, so they are untrusted in the sense of
        /// [ZIP 315](https://zips.z.cash/zip-0315) and need 10 confirmations (roughly 12 minutes)
        /// before they can be spent. Call ``GiftCardRedeemer/check()`` again later.
        case pending
        /// The card's spendable funds do not exceed the fee of the transaction that would sweep
        /// them, and nothing else is on its way: redeeming it would leave nothing for the
        /// recipient. ``GiftCardRedeemer/redeem(to:memo:recordIn:)`` throws
        /// ``ZcashError/giftCardNothingToRedeem`` for it.
        case dust
        /// The card holds nothing: it was already redeemed, or it was never funded (or its funding
        /// transaction is not mined yet, or `birthdayHeight` is past it).
        case empty
    }

    /// What the card can do right now.
    public let state: State
    /// Every shielded value the card wallet holds, spendable or not.
    public let total: Zatoshi
    /// The value that ``GiftCardRedeemer/redeem(to:)`` can sweep now, before the fee.
    public let spendable: Zatoshi
    /// The value still waiting for confirmations: `total - spendable`.
    public let pending: Zatoshi

    /// - Parameters:
    ///   - balance: the card account's balance, if the account has one.
    ///   - spendableCoversFee: whether the spendable value exceeds the fee of the transaction
    ///     that sweeps it; only meaningful when it is non-zero.
    init(balance: AccountBalance?, spendableCoversFee: Bool) {
        let total = balance?.shieldedTotal() ?? .zero
        let spendable = balance?.shieldedSpendableValue ?? .zero
        self.total = total
        self.spendable = spendable
        self.pending = total - spendable
        if spendable > .zero && spendableCoversFee {
            state = .ready
        } else if pending > .zero {
            state = .pending
        } else if spendable > .zero {
            state = .dust
        } else {
            state = .empty
        }
    }
}

/// Redeems a ``GiftCard`` into the user's own wallet through a temporary, isolated wallet.
///
/// The flow is three calls:
///
/// 1. ``check()`` creates the card wallet from the card's seed and birthday, syncs it, and reports
///    what it holds (``GiftCardStatus``): ready, pending confirmations, dust (less than the fee),
///    or empty.
/// 2. ``redeem(to:memo:recordIn:)`` sends the card's entire spendable balance, minus the fee, to
///    the given address. The transaction discards the outgoing viewing key (``OvkPolicy/discard``):
///    the card's key — which its issuer can rederive — cannot reveal where the funds went. It only
///    spends Orchard and Ironwood notes to an Orchard receiver, so it never downloads the Sapling
///    parameters. Given the user's own synchronizer as the destination, the claim is recorded
///    there at once as an untrusted transaction (ZIP 315), so the main wallet shows it immediately
///    and can spend it after the default ten confirmations for an external receive. The issuer
///    and anyone holding the link share the card's spending key; see `docs/GIFT_CARDS.md`.
/// 3. ``cleanup()`` stops the card wallet and deletes every file it created.
///
/// ### Isolation and lifecycle
///
/// The card wallet is an `SDKSynchronizer` of its own, with a custom alias derived from a hash of
/// the card's funding address (never `.default`) and all of its files in a directory of its own
/// under `storageDirectory`. It runs alongside the app's main synchronizer without touching its
/// data. Exchange-rate fetching is off for the card wallet. Tor follows `isTorEnabled`: pass the
/// main wallet's setting, so that a user who chose Tor does not reveal their IP address together
/// with the card's birthday, its sync and the claim.
///
/// The card wallet uses the SDK's transfer confirmation policy (ZIP 315): 3 confirmations for
/// trusted notes and 10 for untrusted ones. Every note on a card comes from another wallet, so
/// it needs 10.
///
/// - The SDK does not stop two synchronizers from sharing an alias, so this type does: only one
///   redeemer per card may be alive in the process at a time. Creating a second one throws
///   ``ZcashError/giftCardRedeemerAlreadyActive`` until the first is cleaned up or released.
/// - Calls on one redeemer are serialized in the order they are made; a ``redeem(to:)`` issued
///   while ``check()`` is syncing runs after it.
/// - Both wallets share the SDK's global database executor, so every wallet-database call of
///   either wallet waits for the other's. Syncing a card's short history is quick, but the main
///   wallet's sync is slower while the card wallet scans, and vice versa.
/// - ``check()`` waits for the card wallet to be up to date. The wallet keeps syncing in the
///   background afterwards, so calling ``check()`` again (for instance while funds are pending)
///   reports the latest balance without waiting for a new sync. Cancelling the calling task
///   stops the wait (the wallet keeps syncing) and throws `CancellationError`.
/// - ``cleanup()`` is always safe for the funds: the card's key is in the link, not in the
///   temporary wallet. Unredeemed funds stay on the card and a new redeemer can sweep them.
/// - Releasing a redeemer without ``cleanup()`` (or a crash, or the app being killed) leaves its
///   files behind until a redeemer for the same card is created and cleaned up. They hold the
///   card's keys and the claim's recipient, so call ``removeLeftoverWallets(in:)`` at launch.
/// - After a redeem whose submission failed, the card wallet considers the notes spent until the
///   transaction expires, so a second ``redeem(to:)`` on the same redeemer finds nothing to
///   spend. Clean up and create a new redeemer to retry; the notes are spent at most once on
///   chain either way.
public actor GiftCardRedeemer {
    /// The outcome of ``redeem(to:memo:recordIn:)``.
    public struct Redemption: Equatable {
        /// The submission result of each created transaction (usually one). A `.success` means a
        /// server accepted it; the funds arrive once it is mined.
        public let results: [TransactionSubmitResult]
        /// Whether every accepted claim transaction was handed to the destination synchronizer as an
        /// untrusted transaction. `false` when no destination was given, when no transaction was
        /// accepted, or when the destination failed to record one; the redemption itself is
        /// unaffected, and the destination learns about the claim when it next syncs, as an
        /// ordinary external receive.
        public let recordedInDestination: Bool
    }

    /// The card being redeemed.
    public let card: GiftCard

    /// The synchronizer alias of the card wallet. It identifies the card, not its key; it is safe
    /// to log.
    public nonisolated let alias: ZcashSynchronizerAlias

    private let owner: UUID
    private let network: ZcashNetwork
    private let rootDirectory: URL
    private let initializer: Initializer
    private let checkpointSource: GiftCardCheckpointSource
    private let synchronizer: SDKSynchronizer
    private var accountUUID: AccountUUID?
    private var isCleanedUp = false
    private var tail: Task<Void, Never>?

    /// Creates a redeemer for `card`. Nothing touches the disk or the network until ``check()``.
    ///
    /// - Parameters:
    ///   - card: the card to redeem.
    ///   - network: the app's network. It must be the card's network.
    ///   - endpoint: the lightwalletd server the card wallet syncs from and submits to.
    ///   - isTorEnabled: whether the card wallet reaches `endpoint` over Tor: its birthday lookup,
    ///     its sync and the claim's submission. Pass the main wallet's setting; with `false` the
    ///     server sees the device's IP address with all three.
    ///   - storageDirectory: the directory under which the card wallet's own directory is created.
    ///     The app's caches or temporary directory is fine: everything in it is deleted by
    ///     ``cleanup()``, and losing it never loses funds.
    ///   - loggingPolicy: logging for the card wallet. Defaults to `.noLogging`, so that the
    ///     transaction linking the card to the user's address does not end up in shared logs.
    /// - Throws: ``ZcashError/giftCardNetworkMismatch`` when the card is for another network, and
    ///   ``ZcashError/giftCardRedeemerAlreadyActive`` when another redeemer for the same card is
    ///   still alive.
    public init(
        card: GiftCard,
        network: ZcashNetwork,
        endpoint: LightWalletEndpoint,
        isTorEnabled: Bool,
        storageDirectory: URL = GiftCardRedeemer.defaultStorageDirectory,
        loggingPolicy: Initializer.LoggingPolicy = .noLogging
    ) throws {
        try self.init(
            card: card,
            network: network,
            endpoint: endpoint,
            isTorEnabled: isTorEnabled,
            storageDirectory: storageDirectory,
            loggingPolicy: loggingPolicy,
            container: DIContainer(),
            makeSynchronizer: { SDKSynchronizer(initializer: $0) }
        )
    }

    init(
        card: GiftCard,
        network: ZcashNetwork,
        endpoint: LightWalletEndpoint,
        isTorEnabled: Bool,
        storageDirectory: URL,
        loggingPolicy: Initializer.LoggingPolicy,
        container: DIContainer,
        makeSynchronizer: (Initializer) -> SDKSynchronizer
    ) throws {
        guard card.network == network.networkType else {
            throw ZcashError.giftCardNetworkMismatch
        }

        let alias = card.synchronizerAlias
        let owner = UUID()
        guard GiftCardRedeemerRegistry.claim(alias, owner: owner) else {
            throw ZcashError.giftCardRedeemerAlreadyActive
        }

        // Every file of the card wallet lives under one directory of its own. The custom alias
        // already prefixes each path's last component, but `wipe()` deletes only the data database
        // and the block cache: the SQLite -wal/-shm files, the aliased Sapling parameter copies,
        // the Tor directory and the general storage (submit plans) would all outlive it. Deleting
        // this directory in `cleanup()` removes them all at once.
        let rootDirectory = storageDirectory.appendingPathComponent(alias.description, isDirectory: true)

        let initializer = Initializer(
            container: container,
            cacheDbURL: nil,
            fsBlockDbRoot: rootDirectory.appendingPathComponent("fs_cache", isDirectory: true),
            generalStorageURL: rootDirectory.appendingPathComponent("general_storage", isDirectory: true),
            dataDbURL: rootDirectory.appendingPathComponent("data.db"),
            torDirURL: rootDirectory.appendingPathComponent("tor", isDirectory: true),
            endpoint: endpoint,
            network: network,
            spendParamsURL: rootDirectory.appendingPathComponent("sapling-spend.params"),
            outputParamsURL: rootDirectory.appendingPathComponent("sapling-output.params"),
            saplingParamsSourceURL: .default,
            alias: alias,
            loggingPolicy: loggingPolicy,
            isTorEnabled: isTorEnabled,
            isExchangeRateEnabled: false
        )

        // The card wallet's birthday is the exact height in the link, not the nearest bundled
        // checkpoint below it (see `GiftCardCheckpointSource`); `prepareIfNeeded()` fetches it.
        let checkpointSource = GiftCardCheckpointSource(bundled: initializer.container.resolve(CheckpointSource.self))
        initializer.container.register(type: CheckpointSource.self, isSingleton: true) { _ in checkpointSource }

        self.card = card
        self.alias = alias
        self.owner = owner
        self.network = network
        self.rootDirectory = rootDirectory
        self.initializer = initializer
        self.checkpointSource = checkpointSource
        self.synchronizer = makeSynchronizer(initializer)
    }

    /// Fetches the server's tree state for the block before the card's birthday, so the card
    /// wallet scans from the birthday itself. A fetch failure, or a state for another height,
    /// leaves the bundled checkpoint in place: slower, never wrong. The fetch goes over Tor when
    /// the card wallet uses it.
    private func fetchExactBirthday() async {
        // The rust parser guarantees a birthday at or above NU5 activation, so `- 1` is a block.
        let height = card.birthdayHeight - 1
        do {
            let sdkFlags = initializer.container.resolve(SDKFlags.self)
            let treeState = try await initializer.lightWalletService.getTreeState(
                BlockID(height: UInt64(height)),
                mode: await sdkFlags.ifTor(.uniqueTor)
            )
            if !checkpointSource.use(treeState, forBirthday: card.birthdayHeight) {
                initializer.logger.warn("Gift card: the server sent a tree state for another height; using the bundled checkpoint")
            }
        } catch {
            initializer.logger.warn("Gift card: tree state for the birthday unavailable, using the bundled checkpoint")
        }
    }

    deinit {
        // A redeemer released without `cleanup()` must not leave its wallet syncing, nor keep the
        // card from being redeemed again. Its files stay behind; see the type's documentation.
        synchronizer.stop()
        GiftCardRedeemerRegistry.release(alias, owner: owner)
    }

    /// Creates (on first use) and syncs the card wallet, then reports what the card holds.
    ///
    /// The first call restores the card wallet from the card's birthday, which downloads and scans
    /// the blocks since then. It returns once the wallet is up to date.
    ///
    /// When the card has spendable funds, this also works out, without creating anything, whether
    /// they cover the fee of the transaction that would sweep them; when they do not, the state is
    /// ``GiftCardStatus/State/dust`` rather than ``GiftCardStatus/State/ready``.
    ///
    /// - Returns: the card's balance and whether it can be redeemed now.
    /// - Throws: the sync error if the card wallet cannot sync (for instance, the server is
    ///   unreachable), `CancellationError` if the calling task is cancelled, and
    ///   ``ZcashError/giftCardRedeemerCleanedUp`` after ``cleanup()``.
    public func check() async throws -> GiftCardStatus {
        try await serialized { redeemer in
            try await redeemer.performCheck()
        }
    }

    /// Sends the card's entire spendable balance, minus the fee, to `recipient`, without recording
    /// the claim anywhere else. See ``redeem(to:memo:recordIn:)``.
    ///
    /// - Returns: the submission result of each created transaction (usually one). A
    ///   `.success` means a server accepted it; the funds arrive once it is mined.
    public func redeem(to recipient: UnifiedAddress, memo: Memo? = nil) async throws -> [TransactionSubmitResult] {
        try await redeem(to: recipient, memo: memo, recordIn: nil).results
    }

    /// Sends the card's entire spendable balance, minus the fee, to `recipient`, and records the
    /// claim in `destination` as an untrusted transaction.
    ///
    /// The transaction discards the outgoing viewing key, so the card's key cannot reveal the
    /// recipient or the amount, and it does not need the Sapling parameters when `recipient` has
    /// an Orchard receiver (every wallet's own unified address does). Only spendable funds are
    /// swept; value still waiting for confirmations stays on the card.
    ///
    /// When `destination` is given, every accepted claim transaction is stored in it once the
    /// submission is over, and marked as untrusted: the wallet shows the receive at once, and
    /// follows the ordinary external-receive policy of [ZIP 315](https://zips.z.cash/zip-0315).
    /// The default transfer policy requires ten confirmations before its funds are spendable.
    /// Constructing the claim here does not establish exclusive control over the card's inputs,
    /// because its issuer and anyone holding the link share the spending key. This works
    /// while `destination` is stopped. A failure to record never fails the redemption, since the
    /// funds are already on their way on chain: it is logged, and reported through
    /// ``Redemption/recordedInDestination``; the destination then learns about the claim when it
    /// next syncs, as an ordinary external receive.
    ///
    /// - Parameters:
    ///   - recipient: the user's own address, on the card's network.
    ///   - memo: an optional memo for the claim transaction.
    ///   - destination: the synchronizer of the wallet `recipient` belongs to, or `nil` to record
    ///     the claim nowhere. Only the SDK's own synchronizers (`SDKSynchronizer`,
    ///     `SlipstreamSynchronizer`) can record it; with any other conformer the claim is not
    ///     recorded and ``Redemption/recordedInDestination`` is `false`.
    /// - Returns: the submission results and whether the destination recorded the claim.
    /// - Throws: ``ZcashError/giftCardRedeemerNotReady`` before ``check()`` has prepared the
    ///   card wallet, ``ZcashError/giftCardNothingToRedeem`` when nothing is spendable or the fee
    ///   would take everything (``GiftCardStatus/State/dust``),
    ///   ``ZcashError/giftCardNetworkMismatch`` for an address on another network, and the
    ///   proposal and creation errors of `Synchronizer.proposeSendMax(accountUUID:recipient:memo:mode:)`
    ///   and `Synchronizer.createProposedTransactions(proposal:spendingKey:ovkPolicy:)`. The
    ///   destination's errors are never thrown. Cancellation observed before native creation throws
    ///   `CancellationError`; creation already underway cannot be rolled back.
    public func redeem(to recipient: UnifiedAddress, memo: Memo?, recordIn destination: Synchronizer?) async throws -> Redemption {
        try await serialized { redeemer in
            try await redeemer.performRedeem(to: recipient, memo: memo, recordIn: destination)
        }
    }

    /// Stops the card wallet and deletes every file it created, then frees the card for another
    /// redeemer. The redeemer cannot be used afterwards. Calling it again does nothing.
    ///
    /// - Throws: the error from deleting the files, if any; the wallet is stopped and the card
    ///   freed regardless.
    public func cleanup() async throws {
        try await serialized(cancellationPolicy: .teardown) { redeemer in
            try await redeemer.performCleanup()
        }
    }

    // MARK: - Private

    private enum CancellationPolicy {
        case cancellable
        case teardown
    }

    /// Runs `operation` after every operation issued before it has finished. Actor isolation alone
    /// does not serialize these calls: each suspends at its awaits, which would let a redeem start
    /// while a check is still syncing, or a cleanup delete the wallet under a redeem.
    private func serialized<T>(
        cancellationPolicy: CancellationPolicy = .cancellable,
        _ operation: @escaping (GiftCardRedeemer) async throws -> T
    ) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            await previous?.value
            if cancellationPolicy == .cancellable {
                try Task.checkCancellation()
            }
            return try await operation(self)
        }
        tail = Task { _ = try? await task.value }
        // Teardown must finish even when its caller is cancelled. Cancellable work forwards
        // cancellation into its own task, including while waiting behind a predecessor.
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            if cancellationPolicy == .cancellable {
                task.cancel()
            }
        }
    }

    private func performCheck() async throws -> GiftCardStatus {
        guard !isCleanedUp else {
            throw ZcashError.giftCardRedeemerCleanedUp
        }

        let accountUUID = try await prepareIfNeeded()

        let restarting: Bool
        switch synchronizer.latestState.syncStatus {
        case .upToDate, .syncing:
            restarting = false
        case .unprepared, .stopped, .error:
            try await synchronizer.start(retry: true)
            restarting = true
        }
        // After a restart the state stream may still replay the error that stopped the previous
        // sync; only a later error belongs to this attempt.
        try await waitUntilUpToDate(ignoringStaleError: restarting)

        let balance = try await synchronizer.getAccountsBalances()[accountUUID]
        var coversFee = true
        if let spendable = balance?.shieldedSpendableValue, spendable > .zero {
            coversFee = try await spendableCoversFee(accountUUID: accountUUID)
        }
        return GiftCardStatus(balance: balance, spendableCoversFee: coversFee)
    }

    private func performRedeem(to recipient: UnifiedAddress, memo: Memo?, recordIn destination: Synchronizer?) async throws -> Redemption {
        guard !isCleanedUp else {
            throw ZcashError.giftCardRedeemerCleanedUp
        }
        guard let accountUUID else {
            throw ZcashError.giftCardRedeemerNotReady
        }
        guard recipient.networkType == card.network else {
            throw ZcashError.giftCardNetworkMismatch
        }

        let balances = try await synchronizer.getAccountsBalances()
        guard let spendable = balances[accountUUID]?.shieldedSpendableValue, spendable > .zero else {
            throw ZcashError.giftCardNothingToRedeem
        }

        let proposal: Proposal
        do {
            proposal = try await synchronizer.proposeSendMax(
                accountUUID: accountUUID,
                recipient: .unified(recipient),
                memo: memo,
                mode: .maxSpendable
            )
        } catch ZcashError.rustProposalInsufficientFunds {
            // The fee would take everything: a dust card.
            throw ZcashError.giftCardNothingToRedeem
        }
        let tool = DerivationTool(networkType: card.network)
        let spendingKey = try card.seed.withBytes { seed in
            try tool.deriveUnifiedSpendingKey(seed: seed, accountIndex: Zip32AccountIndex(0))
        }

        // Preparatory awaits may ignore cancellation. Check before creation can store a claim.
        try Task.checkCancellation()
        let stream = try await synchronizer.createProposedTransactions(
            proposal: proposal,
            spendingKey: spendingKey,
            ovkPolicy: .discard
        )

        var results: [TransactionSubmitResult] = []
        for try await result in stream {
            results.append(result)
        }

        var recorded = false
        if let destination {
            if let recorder = destination as? IncomingTransactionRecording {
                let cardWallet = initializer.rustBackend
                recorded = await Self.record(
                    results,
                    in: recorder,
                    rawTransaction: { txId in try await cardWallet.getTransaction(txId: txId)?.raw },
                    logger: initializer.logger
                )
            } else {
                initializer.logger.warn(
                    "Gift card: the destination cannot record incoming transactions; it will learn about the claim from the chain"
                )
            }
        }
        return Redemption(results: results, recordedInDestination: recorded)
    }

    private func performCleanup() async throws {
        guard !isCleanedUp else {
            return
        }
        isCleanedUp = true
        accountUUID = nil
        defer { GiftCardRedeemerRegistry.release(alias, owner: owner) }

        synchronizer.stop()
        // `wipe()` waits for a running sync to stop and closes the wallet's database connections
        // before deleting its files. A failure here is not fatal: the directory removal below
        // deletes the same files.
        try? await Self.awaitCompletion(of: synchronizer.wipe())

        if FileManager.default.fileExists(atPath: rootDirectory.path) {
            try FileManager.default.removeItem(at: rootDirectory)
        }
    }

    /// Prepares the card wallet from the card's seed and birthday on first use, and returns the
    /// card account.
    private func prepareIfNeeded() async throws -> AccountUUID {
        if let accountUUID {
            return accountUUID
        }

        // A wallet left behind by an earlier redeemer for this card (a crash, a killed app) is
        // never reused: it may have been created from an older checkpoint, or hold a half-done
        // claim. Rebuilding one from the card's birthday costs seconds, so start clean.
        try? FileManager.default.removeItem(at: rootDirectory)

        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        // The directory holds a wallet database for a key that is also in the link; it has no
        // business in a device backup. It is created before the birthday fetch, which may start
        // the card wallet's Tor client in it.
        var directory = rootDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)

        await fetchExactBirthday()

        let synchronizer = self.synchronizer
        let birthday = card.birthdayHeight
        _ = try await card.seed.withBytesAsync { seed in
            try await synchronizer.prepare(
                with: seed,
                walletBirthday: birthday,
                name: "Gift card",
                keySource: nil
            )
        }

        guard let account = try await synchronizer.listAccounts().first else {
            throw ZcashError.giftCardRedeemerNotReady
        }
        accountUUID = account.id
        return account.id
    }

    /// Waits until the card wallet's sync status is up to date, or throws its sync error.
    private func waitUntilUpToDate(ignoringStaleError: Bool) async throws {
        var stateStream = synchronizer.stateStream
        if ignoringStaleError {
            stateStream = stateStream
                .drop { state in
                    if case .error = state.syncStatus { return true }
                    return false
                }
                .eraseToAnyPublisher()
        }

        let waiter = SyncWaiter()
        // The waiter owns the subscription; keep it alive until the continuation resumes.
        defer { withExtendedLifetime(waiter) {} }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiter.begin(continuation: continuation, stateStream: stateStream)
            }
        } onCancel: {
            waiter.finish(.failure(CancellationError()))
        }
    }
}

// MARK: - Leftover card wallets

public extension GiftCardRedeemer {
    /// The directory card wallets are created under unless the app chooses another one.
    static let defaultStorageDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ZcashGiftCards", isDirectory: true)

    /// Deletes the card wallets that earlier redeemers left in `storageDirectory`: released
    /// without ``cleanup()``, or cut short by a crash or the app being killed.
    ///
    /// A leftover card wallet holds the card's keys, its notes and the claim transaction with its
    /// recipient, so call this when the app starts. It never touches the wallet of a redeemer that
    /// is alive in this process, nor anything in `storageDirectory` that is not a card wallet.
    /// Losing a card wallet never loses funds: the card's key is in its link.
    ///
    /// - Parameter storageDirectory: the directory passed to ``init(card:network:endpoint:isTorEnabled:storageDirectory:loggingPolicy:)``.
    /// - Returns: the number of card wallets deleted.
    /// - Throws: the first error from deleting a card wallet; the others are still attempted.
    @discardableResult
    static func removeLeftoverWallets(in storageDirectory: URL = GiftCardRedeemer.defaultStorageDirectory) throws -> Int {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: storageDirectory.path) else {
            return 0
        }
        let prefix = ZcashSynchronizerAlias.custom(GiftCard.aliasPrefix).description

        // The registry stays locked while deleting, so that no redeemer for one of these cards
        // can be created, and start writing its wallet, between the check and the deletion.
        return try GiftCardRedeemerRegistry.withActiveAliases { active in
            let activeNames = Set(active.map(\.description))
            var removed = 0
            var firstError: Error?
            for name in names where name.hasPrefix(prefix) && !activeNames.contains(name) {
                do {
                    try fileManager.removeItem(at: storageDirectory.appendingPathComponent(name, isDirectory: true))
                    removed += 1
                } catch {
                    firstError = firstError ?? error
                }
            }
            if let firstError {
                throw firstError
            }
            return removed
        }
    }
}

// MARK: - Helpers

extension GiftCardRedeemer {
    /// The confirmation policy the card wallet spends with: the backend's transfer policy, 3
    /// confirmations for trusted notes and 10 for untrusted ones (ZIP 315). Card notes are
    /// untrusted, so they need 10. Internal, so that a test pins it.
    func cardWalletConfirmationsPolicy() -> ConfirmationsPolicy? {
        (initializer.rustBackend as? ZcashRustBackend)?.confirmationsPolicy
    }

    /// Whether sweeping the card's spendable funds would leave anything for the recipient.
    ///
    /// librustzcash computes the fee: a send-max proposal (never turned into a transaction) to
    /// the card's own address, which has the same Orchard receiver as any wallet's, fails with
    /// insufficient funds exactly when the fee takes everything.
    private func spendableCoversFee(accountUUID: AccountUUID) async throws -> Bool {
        do {
            _ = try await synchronizer.proposeSendMax(
                accountUUID: accountUUID,
                recipient: .unified(card.fundingAddress),
                memo: nil,
                mode: .maxSpendable
            )
            return true
        } catch ZcashError.rustProposalInsufficientFunds {
            return false
        }
    }

    /// Hands every accepted transaction in `results` to `destination` as an untrusted receive.
    ///
    /// Nothing here can fail the redemption: the transactions are already with the servers. A
    /// missing raw transaction or a destination error is logged — without the error's associated
    /// values, which may echo caller input — and reported through the return value.
    ///
    /// - Parameters:
    ///   - results: the submission results of the claim.
    ///   - destination: the synchronizer to record the claim in.
    ///   - rawTransaction: looks up the raw bytes of a transaction of the card wallet by its id.
    /// - Returns: `true` when at least one transaction was accepted and every accepted one was
    ///   recorded.
    static func record(
        _ results: [TransactionSubmitResult],
        in destination: IncomingTransactionRecording,
        rawTransaction: (Data) async throws -> Data?,
        logger: Logger
    ) async -> Bool {
        var recordedAny = false
        for result in results {
            guard case .success(let txId) = result else { continue }
            do {
                guard let raw = try await rawTransaction(txId) else {
                    logger.warn("Gift card: the claim transaction is not in the card wallet; the destination will learn about it from the chain")
                    return false
                }
                try await destination.recordIncomingTransaction(raw, txId: try TxId([UInt8](txId)))
                recordedAny = true
            } catch {
                logger.warn("Gift card: recording the claim in the destination wallet failed: \(error.localizedDescription)")
                return false
            }
        }
        return recordedAny
    }

    /// Waits for `publisher` to complete, or for `timeout` to pass, whichever comes first.
    ///
    /// `wipe()` reports through a `PassthroughSubject` that a task completes, so a wipe that
    /// finishes before this subscribes would never be observed; the timeout bounds that case.
    private static func awaitCompletion(
        of publisher: AnyPublisher<Void, Error>,
        timeout: TimeInterval = 30
    ) async throws {
        let waiter = PublisherCompletionWaiter()
        // The waiter owns the subscription; keep it alive until the continuation resumes.
        defer { withExtendedLifetime(waiter) {} }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiter.begin(continuation: continuation, publisher: publisher, timeout: timeout)
        }
    }
}

/// The aliases of the redeemers alive in this process.
///
/// `UsedAliasesChecker` exists but nothing calls it, so two synchronizers can share an alias and
/// overwrite each other's files. A gift card's alias is unique to the card, so this registry is
/// what keeps two redeemers of the same card apart.
enum GiftCardRedeemerRegistry {
    private static let lock = NSLock()
    private static var active: [ZcashSynchronizerAlias: UUID] = [:]

    static func claim(_ alias: ZcashSynchronizerAlias, owner: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active[alias] == nil else {
            return false
        }
        active[alias] = owner
        return true
    }

    static func release(_ alias: ZcashSynchronizerAlias, owner: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard active[alias] == owner else {
            return
        }
        active.removeValue(forKey: alias)
    }

    /// Runs `body` with the active aliases, holding off every claim and release until it returns.
    static func withActiveAliases<T>(_ body: (Set<ZcashSynchronizerAlias>) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(Set(active.keys))
    }
}

/// Resumes a continuation once, with the first of: the sync status turning up to date, the sync
/// status turning into an error, or cancellation. The state stream delivers values on arbitrary
/// threads, so every access is under a lock.
private final class SyncWaiter {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancellable: AnyCancellable?
    private var outcome: Result<Void, Error>?

    func begin(continuation: CheckedContinuation<Void, Error>, stateStream: AnyPublisher<SynchronizerState, Never>) {
        lock.lock()
        if let outcome {
            // Cancelled before the continuation existed.
            lock.unlock()
            continuation.resume(with: outcome)
            return
        }
        self.continuation = continuation
        lock.unlock()

        let cancellable = stateStream.sink { [weak self] state in
            switch state.syncStatus {
            case .upToDate:
                self?.finish(.success(()))
            case .error(let error):
                self?.finish(.failure(error))
            case .unprepared, .syncing, .stopped:
                break
            }
        }

        lock.lock()
        if outcome == nil {
            self.cancellable = cancellable
            lock.unlock()
        } else {
            lock.unlock()
            cancellable.cancel()
        }
    }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = result
        let continuation = self.continuation
        self.continuation = nil
        let cancellable = self.cancellable
        self.cancellable = nil
        lock.unlock()

        cancellable?.cancel()
        continuation?.resume(with: result)
    }
}

/// Resumes a continuation once, when a `Void` publisher completes or a timeout passes.
private final class PublisherCompletionWaiter {
    private let lock = NSLock()
    private var cancellable: AnyCancellable?

    func begin(continuation: CheckedContinuation<Void, Error>, publisher: AnyPublisher<Void, Error>, timeout: TimeInterval) {
        let resumed = OneShot()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard resumed.fire() else { return }
            continuation.resume()
        }
        let cancellable = publisher.sink(
            receiveCompletion: { completion in
                guard resumed.fire() else { return }
                switch completion {
                case .finished:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            },
            receiveValue: { _ in }
        )
        lock.lock()
        self.cancellable = cancellable
        lock.unlock()
    }
}

private final class OneShot {
    private let lock = NSLock()
    private var fired = false

    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return false }
        fired = true
        return true
    }
}
