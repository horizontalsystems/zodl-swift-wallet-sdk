//
//  TargetBlockSpacingTests.swift
//  OfflineTests
//
//  The target block spacing schedule through the real FFI, pinned at the real testnet NU7
//  activation height and on mainnet, which has no NU7 activation height.
//

import XCTest
@testable import ZODLSwiftWalletSDK

final class TargetBlockSpacingTests: XCTestCase {
    private let nu7: BlockHeight = 4_465_026
    private let testnetBlossom: BlockHeight = 584_000
    private let mainnetBlossom: BlockHeight = 653_600
    private let testnet = TargetBlockSpacing(network: ZcashNetworkBuilder.network(for: .testnet))
    private let mainnet = TargetBlockSpacing(network: ZcashNetworkBuilder.network(for: .mainnet))

    func testSpacingChangesAtTheNU7ActivationHeight() {
        XCTAssertEqual(testnet.spacing(at: nu7 - 1), 75)
        XCTAssertEqual(testnet.spacing(at: nu7), 25)
        XCTAssertEqual(testnet.spacing(at: testnetBlossom - 1), 150)
        XCTAssertEqual(mainnet.spacing(at: mainnetBlossom), 75)
    }

    func testMainnetStaysAt75SecondsAtFarFutureHeights() {
        XCTAssertEqual(mainnet.spacing(at: 100_000_000), 75)
        XCTAssertEqual(mainnet.spacing(at: BlockHeight(UInt32.max)), 75)
    }

    func testErasAreTheRunsBetweenSpacingChanges() {
        XCTAssertEqual(testnet.era(containing: 0), TargetBlockSpacing.Era(start: 0, end: testnetBlossom, spacing: 150))
        XCTAssertEqual(testnet.era(containing: nu7 - 1), TargetBlockSpacing.Era(start: testnetBlossom, end: nu7, spacing: 75))
        XCTAssertEqual(testnet.era(containing: nu7), TargetBlockSpacing.Era(start: nu7, end: nil, spacing: 25))
        XCTAssertEqual(mainnet.era(containing: 3_000_000), TargetBlockSpacing.Era(start: mainnetBlossom, end: nil, spacing: 75))
    }

    func testSecondsCountEachBlockAtItsOwnSpacing() {
        XCTAssertEqual(testnet.seconds(from: nu7 - 1, to: nu7), 25)
        XCTAssertEqual(testnet.seconds(from: nu7 - 2, to: nu7), 100)
        XCTAssertEqual(testnet.seconds(from: nu7 - 10, to: nu7 + 30), 9 * 75 + 31 * 25)
    }

    func testSecondsOfAReversedRangeAreNegativeAndOfAnEmptyOneZero() {
        XCTAssertEqual(testnet.seconds(from: nu7, to: nu7 - 1), -25)
        XCTAssertEqual(testnet.seconds(from: nu7, to: nu7), 0)
    }

    func testSecondsOverEveryHeightDoNotOverflow() {
        XCTAssertEqual(mainnet.seconds(from: 0, to: BlockHeight(UInt32.max)), 322_171_567_050)
        XCTAssertEqual(mainnet.seconds(from: BlockHeight(UInt32.max), to: 0), -322_171_567_050)
        XCTAssertEqual(mainnet.seconds(from: 0, to: BlockHeight.max), 322_171_567_050)
    }

    func testEstimatedSecondsWithoutASpacingChangeIsTheSingleRateProduct() {
        XCTAssertEqual(testnet.estimatedSeconds(from: 4_000_000, to: 4_000_100, secondsPerBlock: 31.7), Double(100) * 31.7)
        // A range whose first block is the activation block lies wholly in one era.
        XCTAssertEqual(testnet.estimatedSeconds(from: nu7 - 1, to: nu7 + 99, secondsPerBlock: 20), Double(100) * 20)
        XCTAssertEqual(mainnet.estimatedSeconds(from: 3_000_000, to: 3_034_560, secondsPerBlock: 75), Double(34_560) * 75)
    }

    func testEstimatedSecondsScalesTheBlocksPastAChangeBySpeedFactor() {
        // Nine blocks at the measured 60 s, then 31 blocks of 25 s target time at 60 / 75 of the target pace.
        XCTAssertEqual(testnet.estimatedSeconds(from: nu7 - 10, to: nu7 + 30, secondsPerBlock: 60), 9 * 60 + 31 * 25 * 0.8, accuracy: 1e-9)
    }

    func testEstimatedSecondsOfAnEmptyOrReversedRangeIsZero() {
        XCTAssertEqual(testnet.estimatedSeconds(from: nu7, to: nu7, secondsPerBlock: 60), 0)
        XCTAssertEqual(testnet.estimatedSeconds(from: nu7 + 30, to: nu7 - 10, secondsPerBlock: 60), 0)
    }

    func testHeightReachedAfterCountsOnlyWholeBlocks() {
        XCTAssertEqual(testnet.height(reachedAfter: 0, from: nu7), nu7)
        XCTAssertEqual(testnet.height(reachedAfter: 99.9, from: nu7 - 2), nu7 - 1)
        XCTAssertEqual(testnet.height(reachedAfter: 100, from: nu7 - 2), nu7)
        XCTAssertEqual(testnet.height(reachedAfter: 125, from: nu7 - 2), nu7 + 1)
        XCTAssertEqual(testnet.height(reachedAfter: -49.9, from: nu7 + 1), nu7)
        XCTAssertEqual(testnet.height(reachedAfter: -50, from: nu7 + 1), nu7 - 1)
        XCTAssertEqual(mainnet.height(reachedAfter: -1_000_000_000_000, from: 10), 0)
    }

    func testHeightReachedAfterInvertsSeconds() {
        for from in [nu7 - 200, nu7 - 1, nu7, nu7 + 500] {
            for to in [nu7 - 300, nu7 - 1, nu7, nu7 + 1, nu7 + 700] {
                XCTAssertEqual(testnet.height(reachedAfter: testnet.seconds(from: from, to: to), from: from), to, "from \(from) to \(to)")
            }
        }
    }

    func testDefaultTxTargetHeightInvertsTheExpiryDelta() {
        XCTAssertEqual(mainnet.defaultTxTargetHeight(forExpiryHeight: 3_000_040), 3_000_000)
        XCTAssertEqual(testnet.defaultTxTargetHeight(forExpiryHeight: nu7 + 39), nu7 - 1)
        XCTAssertEqual(testnet.defaultTxTargetHeight(forExpiryHeight: nu7 + 120), nu7)
        for expiry in (nu7 + 40)...(nu7 + 119) {
            XCTAssertEqual(testnet.defaultTxTargetHeight(forExpiryHeight: expiry), expiry - 120, "expiry \(expiry)")
        }
    }

    /// Registration is process-global, so this registers exactly the heights
    /// `RegtestActivationHeightsTests` registers for its NU7 test; the state ends the same whichever runs last.
    func testACustomNetworkAnswersWithItsRegisteredHeights() {
        ZcashRustBackend.setCustomNetwork(
            base: .regtest,
            NetworkActivationHeights(
                overwinter: 1,
                sapling: 1,
                blossom: 1,
                heartwood: 1,
                canopy: 1,
                nu5: 1,
                nu6: 1,
                nu6_1: 1,
                nu6_2: 1,
                nu6_3: 100,
                nu7: 300
            )
        )
        let custom = TargetBlockSpacing(networkType: .regtest)
        XCTAssertEqual(custom.spacing(at: 0), 150)
        XCTAssertEqual(custom.era(containing: 299), TargetBlockSpacing.Era(start: 1, end: 300, spacing: 75))
        XCTAssertEqual(custom.era(containing: 300), TargetBlockSpacing.Era(start: 300, end: nil, spacing: 25))
    }

    func testValuesAreEqualExactlyWhenTheirNetworksAre() {
        XCTAssertEqual(testnet, TargetBlockSpacing(networkType: .testnet))
        XCTAssertNotEqual(testnet, mainnet)
    }
}
