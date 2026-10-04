//
//  GiftCardCheckpointSource.swift
//  ZcashLightClientKit
//
//  A gift card's link carries the height its funds were received at (or just below it), so its
//  wallet should start scanning there. The bundled checkpoints only exist every 2,500 blocks on
//  mainnet and every 10,000 on testnet, so a card restored from them scans days of blocks it
//  cannot contain. This source serves a checkpoint built from the server's tree state for the
//  exact height when the redeemer managed to fetch one, and the bundled grid otherwise.
//

import Foundation

final class GiftCardCheckpointSource: CheckpointSource {
    private let bundled: CheckpointSource
    private let lock = NSLock()
    private var exact: Checkpoint?

    init(bundled: CheckpointSource) {
        self.bundled = bundled
    }

    var network: NetworkType { bundled.network }

    var saplingActivation: Checkpoint { bundled.saplingActivation }

    /// Remembers a checkpoint fetched for the card's birthday; `birthday(for:)` serves it for any
    /// birthday at or above its height.
    func use(_ checkpoint: Checkpoint) {
        lock.lock()
        exact = checkpoint
        lock.unlock()
    }

    func latestKnownCheckpoint() -> Checkpoint {
        bundled.latestKnownCheckpoint()
    }

    func birthday(for height: BlockHeight) -> Checkpoint {
        lock.lock()
        let exact = self.exact
        lock.unlock()
        if let exact, exact.height <= height {
            return exact
        }
        return bundled.birthday(for: height)
    }

    func estimateBirthdayHeight(for date: Date) -> BlockHeight {
        bundled.estimateBirthdayHeight(for: date)
    }

    func estimateTimestamp(for height: BlockHeight) -> TimeInterval? {
        bundled.estimateTimestamp(for: height)
    }
}

extension Checkpoint {
    /// A checkpoint from a server tree state; the optional trees are absent when the server
    /// sends them empty.
    init(treeState: TreeState) {
        self.init(
            height: BlockHeight(treeState.height),
            hash: treeState.hash,
            time: treeState.time,
            saplingTree: treeState.saplingTree,
            orchardTree: treeState.orchardTree.isEmpty ? nil : treeState.orchardTree,
            ironwoodTree: treeState.ironwoodTree.isEmpty ? nil : treeState.ironwoodTree
        )
    }
}
