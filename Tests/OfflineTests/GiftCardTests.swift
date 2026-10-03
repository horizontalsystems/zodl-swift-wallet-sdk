//
//  GiftCardTests.swift
//  ZcashLightClientKit-Unit-Tests
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class GiftCardTests: ZcashTestCase {
    /// Vizor's published, never-funded reference vector: 32 zero bytes of entropy, which is the
    /// phrase of 23 times "abandon" followed by "art".
    static let vizorV3Payload = [
        "WyJtYWluIiwiQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQSIsMzQ4MzE0MSwiMTAwMDAwMCIsImtuaWdodE1hZ2ljIiwx",
        "MS4xNzQ3LCJJdCdzIGEgZ3JlYXQgZGF5IHRvIHNoaWVsZCB5b3VyIFpFQyDwn5uh77iPIl0"
    ].joined()
    static let vizorV3Link = "https://link.vizor.cash/payment-links/open#v3=\(vizorV3Payload)"

    /// The BIP 39 seed (empty passphrase) of the all-zero 256-bit entropy.
    static let vizorV3SeedHex =
        "408b285c123836004f4b8842c89324c1f01382450c0d439af345ba7fc49acf705489c6fc77dbd4e3dc1dd8cc6bc9f043db8ada1e243c4a0eafb290d399480840"

    /// A testnet card in the Zodl format: entropy of 32 bytes of 0x07.
    static let zodlTestnetKey = "zgifttest1qurswpc8qurswpc8qurswpc8qurswpc8qurswpc8qurswpc8qurs98m07r"
    static let zodlTestnetLink = "https://gift.zodl.com/#v=1&key=\(zodlTestnetKey)&height=3000000&amount=0.5&desc=Hi%20there%21"

    // MARK: - Parsing

    func testParsesTheVizorV3Vector() throws {
        let card = try GiftCard(link: Self.vizorV3Link)

        XCTAssertEqual(card.origin, .vizorV3)
        XCTAssertEqual(card.network, .mainnet)
        XCTAssertEqual(card.birthdayHeight, 3_483_141)
        XCTAssertEqual(card.statedAmount, Zatoshi(1_000_000))
        XCTAssertEqual(card.message, "It's a great day to shield your ZEC 🛡️")
        XCTAssertEqual(card.seed.bytes, [UInt8](try XCTUnwrap(Self.vizorV3SeedHex.hexadecimal)))
        XCTAssertTrue(card.fundingAddress.stringEncoded.hasPrefix("u1"))
        // The funding address is Orchard-only.
        XCTAssertEqual(try card.fundingAddress.availableReceiverTypecodes(), [.orchard])
    }

    func testParsesAZodlTestnetLink() throws {
        // Surrounding whitespace, as a scanner or a paste may add, is ignored.
        let card = try GiftCard(link: "  \(Self.zodlTestnetLink)\n")

        XCTAssertEqual(card.origin, .zodl)
        XCTAssertEqual(card.network, .testnet)
        XCTAssertEqual(card.birthdayHeight, 3_000_000)
        XCTAssertEqual(card.statedAmount, Zatoshi(50_000_000))
        XCTAssertEqual(card.message, "Hi there!")
        XCTAssertEqual(card.seed.bytes.count, 64)
        XCTAssertTrue(card.fundingAddress.stringEncoded.hasPrefix("utest1"))
        XCTAssertEqual(try card.fundingAddress.availableReceiverTypecodes(), [.orchard])
    }

    func testOptionalFieldsMayBeAbsent() throws {
        let card = try GiftCard(link: "https://gift.zodl.com/#v=1&key=\(Self.zodlTestnetKey)&height=3000000")

        XCTAssertNil(card.statedAmount)
        XCTAssertNil(card.message)
    }

    func testTheSeedDerivesTheFundingAccount() throws {
        let card = try GiftCard(link: Self.vizorV3Link)
        let tool = DerivationTool(networkType: card.network)
        let usk = try tool.deriveUnifiedSpendingKey(seed: card.seed.bytes, accountIndex: Zip32AccountIndex(0))
        let ufvk = try tool.deriveUnifiedFullViewingKey(from: usk)

        XCTAssertFalse(ufvk.stringEncoded.isEmpty)
        XCTAssertEqual(card, try GiftCard(link: Self.vizorV3Link))
    }

    func testRejectsBadLinksWithoutEchoingThem() {
        let secretPart = String(Self.zodlTestnetKey.dropFirst(10))
        let links = [
            "",
            "https://example.com/#v=1&key=\(Self.zodlTestnetKey)&height=1",
            "https://gift.zodl.com/#v=2&key=\(Self.zodlTestnetKey)&height=1",
            "https://gift.zodl.com/#v=1&key=\(Self.zodlTestnetKey)",
            "https://gift.zodl.com/#v=1&key=\(Self.zodlTestnetKey)x&height=1",
            "https://gift.zodl.com/#v=1&key=\(Self.zodlTestnetKey)&height=0",
            "https://gift.zodl.com/#v=1&key=\(Self.zodlTestnetKey)\u{0}&height=1"
        ]

        for link in links {
            XCTAssertThrowsError(try GiftCard(link: link), link) { error in
                guard case ZcashError.rustParseGiftCardLink(let message) = error else {
                    return XCTFail("Unexpected error \(error.localizedDescription)")
                }
                XCTAssertFalse(message.isEmpty)
                XCTAssertFalse(message.contains(secretPart), message)
                XCTAssertFalse(error.localizedDescription.contains(secretPart))
            }
        }
    }

    // MARK: - Redaction

    func testTextualRepresentationsAreRedacted() throws {
        let card = try GiftCard(link: Self.vizorV3Link)
        let seedHex = card.seed.bytes.map { String(format: "%02x", $0) }.joined()

        var dumped = ""
        dump(card, to: &dumped)
        let representations = [
            String(describing: card),
            String(reflecting: card),
            "\(card)",
            dumped,
            String(describing: card.seed),
            "\(Mirror(reflecting: card).children.map { "\($0.label ?? ""): \($0.value)" })"
        ]

        for representation in representations {
            XCTAssertFalse(representation.contains(seedHex), representation)
            XCTAssertFalse(representation.contains("\(card.seed.bytes)"), representation)
        }
        XCTAssertEqual(String(describing: card), "--redacted--")
        XCTAssertEqual(String(describing: card.seed), "--redacted--")
    }

    // MARK: - Alias

    func testAliasIsStablePerCardAndDistinctBetweenCards() throws {
        let vizor = try GiftCard(link: Self.vizorV3Link)
        let zodl = try GiftCard(link: Self.zodlTestnetLink)

        XCTAssertEqual(vizor.synchronizerAlias, try GiftCard(link: Self.vizorV3Link).synchronizerAlias)
        XCTAssertNotEqual(vizor.synchronizerAlias, zodl.synchronizerAlias)
        XCTAssertNotEqual(vizor.synchronizerAlias, .default)

        guard case let .custom(name) = vizor.synchronizerAlias else {
            return XCTFail("A gift card must never use the default alias")
        }
        XCTAssertTrue(name.hasPrefix("giftcard_"))
        XCTAssertEqual(name.count, "giftcard_".count + 16)
        XCTAssertFalse(name.contains(vizor.fundingAddress.stringEncoded))
    }

    // MARK: - Status

    func testStatusClassifiesBalances() {
        func balance(spendable: Int64, pending: Int64) -> AccountBalance {
            AccountBalance(
                saplingBalance: .zero,
                orchardBalance: PoolBalance(
                    spendableValue: Zatoshi(spendable / 2),
                    changePendingConfirmation: .zero,
                    valuePendingSpendability: .zero
                ),
                ironwoodBalance: PoolBalance(
                    spendableValue: Zatoshi(spendable - spendable / 2),
                    changePendingConfirmation: .zero,
                    valuePendingSpendability: Zatoshi(pending)
                ),
                unshielded: .zero
            )
        }

        let ready = GiftCardStatus(balance: balance(spendable: 1_010_000, pending: 0))
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(ready.spendable, Zatoshi(1_010_000))
        XCTAssertEqual(ready.pending, .zero)

        let partly = GiftCardStatus(balance: balance(spendable: 10_000, pending: 500))
        XCTAssertEqual(partly.state, .ready)
        XCTAssertEqual(partly.total, Zatoshi(10_500))
        XCTAssertEqual(partly.pending, Zatoshi(500))

        let pending = GiftCardStatus(balance: balance(spendable: 0, pending: 1_010_000))
        XCTAssertEqual(pending.state, .pending)
        XCTAssertEqual(pending.spendable, .zero)
        XCTAssertEqual(pending.pending, Zatoshi(1_010_000))

        XCTAssertEqual(GiftCardStatus(balance: balance(spendable: 0, pending: 0)).state, .empty)
        XCTAssertEqual(GiftCardStatus(balance: nil).state, .empty)
    }

    // MARK: - Redeemer lifecycle

    func testRedeemerRefusesACardForAnotherNetwork() throws {
        let card = try GiftCard(link: Self.vizorV3Link)

        XCTAssertThrowsError(
            try GiftCardRedeemer(
                card: card,
                network: ZcashNetworkBuilder.network(for: .testnet),
                endpoint: LightWalletEndpointBuilder.default,
                storageDirectory: testTempDirectory
            )
        ) { error in
            guard case ZcashError.giftCardNetworkMismatch = error else {
                return XCTFail("Unexpected error \(error.localizedDescription)")
            }
        }
    }

    func testOnlyOneRedeemerPerCardIsActiveAndCleanupRemovesItsFiles() async throws {
        let card = try GiftCard(link: Self.zodlTestnetLink)
        let network = ZcashNetworkBuilder.network(for: .testnet)

        let redeemer = try GiftCardRedeemer(
            card: card,
            network: network,
            endpoint: LightWalletEndpointBuilder.default,
            storageDirectory: testTempDirectory
        )
        XCTAssertEqual(redeemer.alias, card.synchronizerAlias)

        XCTAssertThrowsError(
            try GiftCardRedeemer(
                card: card,
                network: network,
                endpoint: LightWalletEndpointBuilder.default,
                storageDirectory: testTempDirectory
            )
        ) { error in
            guard case ZcashError.giftCardRedeemerAlreadyActive = error else {
                return XCTFail("Unexpected error \(error.localizedDescription)")
            }
        }

        // A redeem before `check()` has prepared the card wallet is refused.
        do {
            _ = try await redeemer.redeem(to: card.fundingAddress)
            XCTFail("redeem(to:) must require check()")
        } catch ZcashError.giftCardRedeemerNotReady {
        } catch {
            XCTFail("Unexpected error \(error.localizedDescription)")
        }

        // Leftover files of the card wallet, as a crash could leave them, are all removed.
        let cardDirectory = testTempDirectory.appendingPathComponent(card.synchronizerAlias.description, isDirectory: true)
        try FileManager.default.createDirectory(at: cardDirectory, withIntermediateDirectories: true)
        for leftover in ["c_x_data.db-wal", "c_x_data.db-shm", "c_x_sapling-spend.params"] {
            FileManager.default.createFile(atPath: cardDirectory.appendingPathComponent(leftover).path, contents: Data([1]))
        }

        try await redeemer.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cardDirectory.path))

        // Cleanup is idempotent, and the redeemer is unusable afterwards.
        try await redeemer.cleanup()
        do {
            _ = try await redeemer.check()
            XCTFail("check() must fail after cleanup()")
        } catch ZcashError.giftCardRedeemerCleanedUp {
        } catch {
            XCTFail("Unexpected error \(error.localizedDescription)")
        }

        // The card is free again.
        let next = try GiftCardRedeemer(
            card: card,
            network: network,
            endpoint: LightWalletEndpointBuilder.default,
            storageDirectory: testTempDirectory
        )
        try await next.cleanup()
    }

    func testReleasingARedeemerFreesTheCard() throws {
        let card = try GiftCard(link: Self.zodlTestnetLink)
        let network = ZcashNetworkBuilder.network(for: .testnet)

        var redeemer: GiftCardRedeemer? = try GiftCardRedeemer(
            card: card,
            network: network,
            endpoint: LightWalletEndpointBuilder.default,
            storageDirectory: testTempDirectory
        )
        XCTAssertNotNil(redeemer)
        redeemer = nil

        XCTAssertNoThrow(
            try GiftCardRedeemer(
                card: card,
                network: network,
                endpoint: LightWalletEndpointBuilder.default,
                storageDirectory: testTempDirectory
            )
        )
    }
}
