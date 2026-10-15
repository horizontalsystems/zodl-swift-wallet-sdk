//
//  BundleCheckpointSource.swift
//
//
//  Created by Francisco Gindre on 2023-10-30.
//

import Foundation

struct BundleCheckpointSource: CheckpointSource {
    var network: NetworkType

    var saplingActivation: Checkpoint

    init(network: NetworkType) {
        self.network = network
        self.saplingActivation = if network == .mainnet { Checkpoint.mainnetMin } else { Checkpoint.testnetMin }
    }

    func latestKnownCheckpoint() -> Checkpoint {
        Checkpoint.birthday(
            with: .max,
            checkpointDirectory: BundleCheckpointURLProvider.default.url(self.network)
        ) ?? saplingActivation
    }

    func birthday(for height: BlockHeight) -> Checkpoint {
        Checkpoint.birthday(
            with: height,
            checkpointDirectory: BundleCheckpointURLProvider.default.url(self.network)
        ) ?? saplingActivation
    }

    /// The height of the newest bundled checkpoint strictly before `date`, the newest checkpoint for a date at
    /// or after its time, or Sapling activation when none precedes `date`. Checkpoint times decide; the target
    /// spacing only picks where the walk starts.
    func estimateBirthdayHeight(for date: Date) -> BlockHeight {
        let directory = BundleCheckpointURLProvider.default.url(network)
        let heights = Checkpoint.bundledHeights(checkpointDirectory: directory)
        let dateTime = date.timeIntervalSince1970
        let latestCheckpoint = Checkpoint.birthday(with: .max, among: heights, checkpointDirectory: directory) ?? saplingActivation

        guard dateTime < TimeInterval(latestCheckpoint.time) else {
            return latestCheckpoint.height
        }

        // The guess assumes every block since the date took exactly its target spacing; real blocks drift, so
        // it only picks where to start reading checkpoint times.
        let guess = TargetBlockSpacing(networkType: network).height(
            reachedAfter: dateTime - TimeInterval(latestCheckpoint.time),
            from: latestCheckpoint.height
        )
        // The walk steps through indexes of `heights`, never through the heights the files decode to, so it ends
        // however the files are named or what they hold.
        var index = heights.lastIndex { $0 <= guess } ?? 0
        guard var candidate = Checkpoint.bundledCheckpoint(at: index, among: heights, checkpointDirectory: directory) else {
            return saplingActivation.height
        }

        while TimeInterval(candidate.time) >= dateTime {
            guard let earlier = Checkpoint.bundledCheckpoint(at: index - 1, among: heights, checkpointDirectory: directory) else {
                return saplingActivation.height
            }
            index -= 1
            candidate = earlier
        }

        while
            let next = Checkpoint.bundledCheckpoint(at: index + 1, among: heights, checkpointDirectory: directory),
            TimeInterval(next.time) < dateTime {
            index += 1
            candidate = next
        }

        return candidate.height
    }

    func estimateTimestamp(for height: BlockHeight) -> TimeInterval? {
        let blockInterval: BlockHeight = network == .mainnet ? 2500 : 10_000
        var checkpointHeight = (height / blockInterval) * blockInterval

        // Ensure sapling activation is the lowest possible
        let saplingActivationHeight = network == .mainnet
        ? ZcashMainnet().constants.saplingActivationHeight
        : ZcashTestnet().constants.saplingActivationHeight

        if checkpointHeight < saplingActivationHeight {
            checkpointHeight = saplingActivationHeight
        }

        var checkpoint: Checkpoint?

        while checkpoint == nil || checkpointHeight > blockInterval {
            checkpoint = Checkpoint.birthday(
                with: BlockHeight(checkpointHeight),
                checkpointDirectory: BundleCheckpointURLProvider.default.url(self.network)
            )

            if let checkpoint {
                return TimeInterval(checkpoint.time)
            }

            checkpointHeight -= blockInterval

            if checkpointHeight < saplingActivationHeight {
                checkpointHeight = saplingActivationHeight
            }
        }

        return nil
    }
}
