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
        /// The card has funds that can be redeemed now: ``GiftCardStatus/spendable`` is non-zero.
        case ready
        /// The card has funds, but none are spendable yet: they are waiting for confirmations.
        ///
        /// Card funds come from another wallet, so they need 10 confirmations (roughly 12 minutes)
        /// before they can be spent. Call ``GiftCardRedeemer/check()`` again later.
        case pending
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

    init(balance: AccountBalance?) {
        let total = balance?.shieldedTotal() ?? .zero
        let spendable = balance?.shieldedSpendableValue ?? .zero
        self.total = total
        self.spendable = spendable
        self.pending = total - spendable
        if spendable > .zero {
            state = .ready
        } else if total > .zero {
            state = .pending
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
///    what it holds (``GiftCardStatus``): ready, pending confirmations, or empty.
/// 2. ``redeem(to:)`` sends the card's entire spendable balance, minus the fee, to the given
///    address. The transaction discards the outgoing viewing key (``OvkPolicy/discard``): the
///    card's key — which its issuer can rederive — cannot reveal where the funds went. It only
///    spends Orchard and Ironwood notes to an Orchard receiver, so it never downloads the Sapling
///    parameters.
/// 3. ``cleanup()`` stops the card wallet and deletes every file it created.
///
/// ### Isolation and lifecycle
///
/// The card wallet is an `SDKSynchronizer` of its own, with a custom alias derived from a hash of
/// the card's funding address (never `.default`) and all of its files in a directory of its own
/// under `storageDirectory`. It runs alongside the app's main synchronizer without touching its
/// data. Tor and exchange-rate fetching are off for the card wallet.
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
/// - Releasing a redeemer without ``cleanup()`` stops its wallet but leaves its files behind
///   until a redeemer for the same card is created and cleaned up.
/// - After a redeem whose submission failed, the card wallet considers the notes spent until the
///   transaction expires, so a second ``redeem(to:)`` on the same redeemer finds nothing to
///   spend. Clean up and create a new redeemer to retry; the notes are spent at most once on
///   chain either way.
public actor GiftCardRedeemer {
    /// The card being redeemed.
    public let card: GiftCard

    /// The synchronizer alias of the card wallet. It identifies the card, not its key; it is safe
    /// to log.
    public nonisolated let alias: ZcashSynchronizerAlias

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
        storageDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("ZcashGiftCards", isDirectory: true),
        loggingPolicy: Initializer.LoggingPolicy = .noLogging
    ) throws {
        guard card.network == network.networkType else {
            throw ZcashError.giftCardNetworkMismatch
        }

        let alias = card.synchronizerAlias
        guard GiftCardRedeemerRegistry.claim(alias) else {
            throw ZcashError.giftCardRedeemerAlreadyActive
        }

        // Every file of the card wallet lives under one directory of its own. The custom alias
        // already prefixes each path's last component, but `wipe()` deletes only the data database
        // and the block cache: the SQLite -wal/-shm files, the aliased Sapling parameter copies,
        // the Tor directory and the general storage (submit plans) would all outlive it. Deleting
        // this directory in `cleanup()` removes them all at once.
        let rootDirectory = storageDirectory.appendingPathComponent(alias.description, isDirectory: true)

        let initializer = Initializer(
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
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )

        // The card wallet's birthday is the exact height in the link, not the nearest bundled
        // checkpoint below it (see `GiftCardCheckpointSource`); `prepareIfNeeded()` fetches it.
        let checkpointSource = GiftCardCheckpointSource(bundled: initializer.container.resolve(CheckpointSource.self))
        initializer.container.register(type: CheckpointSource.self, isSingleton: true) { _ in checkpointSource }

        self.card = card
        self.alias = alias
        self.network = network
        self.rootDirectory = rootDirectory
        self.initializer = initializer
        self.checkpointSource = checkpointSource
        self.synchronizer = SDKSynchronizer(initializer: initializer)
    }

    /// Fetches the server's tree state for the block before the card's birthday, so the card
    /// wallet scans from the birthday itself. A fetch failure leaves the bundled checkpoint in
    /// place: slower, never wrong.
    private func fetchExactBirthday() async {
        guard card.birthdayHeight > 1 else { return }
        do {
            let treeState = try await initializer.lightWalletService.getTreeState(
                BlockID(height: UInt64(card.birthdayHeight - 1)),
                mode: .direct
            )
            checkpointSource.use(Checkpoint(treeState: treeState))
        } catch {
            initializer.logger.warn("Gift card: tree state for the birthday unavailable, using the bundled checkpoint")
        }
    }

    deinit {
        // A redeemer released without `cleanup()` must not leave its wallet syncing, nor keep the
        // card from being redeemed again. Its files stay behind; see the type's documentation.
        synchronizer.stop()
        GiftCardRedeemerRegistry.release(alias)
    }

    /// Creates (on first use) and syncs the card wallet, then reports what the card holds.
    ///
    /// The first call restores the card wallet from the card's birthday, which downloads and scans
    /// the blocks since then. It returns once the wallet is up to date.
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

    /// Sends the card's entire spendable balance, minus the fee, to `recipient`.
    ///
    /// The transaction discards the outgoing viewing key, so the card's key cannot reveal the
    /// recipient or the amount, and it does not need the Sapling parameters when `recipient` has
    /// an Orchard receiver (every wallet's own unified address does). Only spendable funds are
    /// swept; value still waiting for confirmations stays on the card.
    ///
    /// - Parameter recipient: the user's own address, on the card's network.
    /// - Returns: the submission result of each created transaction (usually one). A
    ///   `.success` means a server accepted it; the funds arrive once it is mined.
    /// - Throws: ``ZcashError/giftCardRedeemerNotReady`` before ``check()`` has prepared the
    ///   card wallet, ``ZcashError/giftCardNothingToRedeem`` when nothing is spendable,
    ///   ``ZcashError/giftCardNetworkMismatch`` for an address on another network, and the
    ///   proposal and creation errors of `Synchronizer.proposeSendMax(accountUUID:recipient:memo:mode:)`
    ///   and `Synchronizer.createProposedTransactions(proposal:spendingKey:ovkPolicy:)`.
    public func redeem(to recipient: UnifiedAddress, memo: Memo? = nil) async throws -> [TransactionSubmitResult] {
        try await serialized { redeemer in
            try await redeemer.performRedeem(to: recipient, memo: memo)
        }
    }

    /// Stops the card wallet and deletes every file it created, then frees the card for another
    /// redeemer. The redeemer cannot be used afterwards. Calling it again does nothing.
    ///
    /// - Throws: the error from deleting the files, if any; the wallet is stopped and the card
    ///   freed regardless.
    public func cleanup() async throws {
        try await serialized { redeemer in
            try await redeemer.performCleanup()
        }
    }

    // MARK: - Private

    /// Runs `operation` after every operation issued before it has finished. Actor isolation alone
    /// does not serialize these calls: each suspends at its awaits, which would let a redeem start
    /// while a check is still syncing, or a cleanup delete the wallet under a redeem.
    private func serialized<T>(_ operation: @escaping (GiftCardRedeemer) async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            await previous?.value
            return try await operation(self)
        }
        tail = Task { _ = try? await task.value }
        // The operation runs in its own task so that the next one can wait for it; forward the
        // caller's cancellation to it.
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
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

        let balances = try await synchronizer.getAccountsBalances()
        return GiftCardStatus(balance: balances[accountUUID])
    }

    private func performRedeem(to recipient: UnifiedAddress, memo: Memo?) async throws -> [TransactionSubmitResult] {
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

        let proposal = try await synchronizer.proposeSendMax(
            accountUUID: accountUUID,
            recipient: .unified(recipient),
            memo: memo,
            mode: .maxSpendable
        )
        let spendingKey = try DerivationTool(networkType: card.network)
            .deriveUnifiedSpendingKey(seed: card.seed.bytes, accountIndex: Zip32AccountIndex(0))

        let stream = try await synchronizer.createProposedTransactions(
            proposal: proposal,
            spendingKey: spendingKey,
            ovkPolicy: .discard
        )

        var results: [TransactionSubmitResult] = []
        for try await result in stream {
            results.append(result)
        }
        return results
    }

    private func performCleanup() async throws {
        guard !isCleanedUp else {
            return
        }
        isCleanedUp = true
        accountUUID = nil
        defer { GiftCardRedeemerRegistry.release(alias) }

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

        await fetchExactBirthday()
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        // The directory holds a wallet database for a key that is also in the link; it has no
        // business in a device backup.
        var directory = rootDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)

        _ = try await synchronizer.prepare(
            with: card.seed.bytes,
            walletBirthday: card.birthdayHeight,
            name: "Gift card",
            keySource: nil
        )

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
    private static var active: Set<ZcashSynchronizerAlias> = []

    static func claim(_ alias: ZcashSynchronizerAlias) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active.insert(alias).inserted
    }

    static func release(_ alias: ZcashSynchronizerAlias) {
        lock.lock()
        defer { lock.unlock() }
        active.remove(alias)
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
