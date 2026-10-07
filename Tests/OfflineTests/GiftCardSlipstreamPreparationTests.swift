import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class GiftCardSlipstreamPreparationTests: ZcashTestCase {
    func testRestoreUsesInjectedAnchorWithoutNetwork() async throws {
        let fixture = try await GiftCardSlipstreamFixture.make(
            storageDirectory: testTempDirectory,
            isTorEnabled: false
        )
        await fixture.anchor.setResponse(SlipstreamRestoreAnchor(height: 4_460_000, treeState: nil))

        let result = try await fixture.synchronizer.prepare(
            with: fixture.card.seed.withBytes { $0 },
            walletBirthday: 3_000_000,
            name: "Gift card",
            keySource: nil
        )

        guard case .success = result else {
            return XCTFail("Expected a prepared wallet")
        }
        let calls = await fixture.anchor.calls
        XCTAssertEqual(calls.count, 1, "The restore must use the injected offline resolver")
        let call = try XCTUnwrap(calls.first)
        XCTAssertTrue(call.isRestore)
        XCTAssertEqual(call.birthday, 3_000_000)
        XCTAssertEqual(call.fallbackCheckpointHeight, 4_460_000)
        XCTAssertEqual(call.endpoint.host, "127.0.0.1")
        XCTAssertEqual(call.endpoint.port, 1)
        XCTAssertEqual(call.network.networkType, .testnet)
        XCTAssertNil(call.torDirPath)

        let created = try XCTUnwrap(fixture.backend.createAccountSeedTreeStateRecoverUntilNameKeySourceReceivedArguments)
        XCTAssertEqual(created.treeState.height, 3_000_000)
        XCTAssertEqual(created.treeState.hash, "0031432018aa59e440804fa87974ec791ae174fa2909470f3c3a8a93842a659f")
        XCTAssertEqual(created.recoverUntil, 4_460_000)
        XCTAssertEqual(fixture.synchronizer.latestState.accountsBalances[fixture.account.id], fixture.balance)
        XCTAssertEqual(fixture.synchronizer.latestState.latestBlockHeight, 3_000_010)
        XCTAssertEqual(fixture.service.latestBlockHeightModeCallsCount, 0)
        XCTAssertEqual(fixture.service.getTreeStateModeCallsCount, 0)
    }

    func testProtectedRestorePassesTorDirectoryAndNeverCallsDirectService() async throws {
        let fixture = try await GiftCardSlipstreamFixture.make(
            storageDirectory: testTempDirectory,
            isTorEnabled: true
        )
        await fixture.anchor.setResponse(SlipstreamRestoreAnchor(height: 4_460_000, treeState: nil))

        _ = try await fixture.synchronizer.prepare(
            with: fixture.card.seed.withBytes { $0 },
            walletBirthday: 3_000_000,
            name: "Gift card",
            keySource: nil
        )

        let calls = await fixture.anchor.calls
        let call = try XCTUnwrap(calls.first)
        let expectedDirectory = fixture.torDirectory.appendingPathComponent("slipstream", isDirectory: true)
        XCTAssertEqual(call.torDirPath, expectedDirectory.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedDirectory.path))
        XCTAssertEqual(fixture.service.latestBlockHeightModeCallsCount, 0)
        XCTAssertEqual(fixture.service.getTreeStateModeCallsCount, 0)
    }

    func testDirectRestorePassesNilTorDirectory() async throws {
        let fixture = try await GiftCardSlipstreamFixture.make(
            storageDirectory: testTempDirectory,
            isTorEnabled: false
        )
        await fixture.anchor.setResponse(SlipstreamRestoreAnchor(height: 4_460_000, treeState: nil))

        _ = try await fixture.synchronizer.prepare(
            with: fixture.card.seed.withBytes { $0 },
            walletBirthday: 2_990_000,
            name: "Gift card",
            keySource: nil
        )

        let calls = await fixture.anchor.calls
        let call = try XCTUnwrap(calls.first)
        XCTAssertNil(call.torDirPath)
        XCTAssertEqual(fixture.service.latestBlockHeightModeCallsCount, 0)
        XCTAssertEqual(fixture.service.getTreeStateModeCallsCount, 0)
    }

    func testOfflineRestoreKeepsNonemptyRecoveryBeyondLatestCheckpoint() async throws {
        let fixture = try await GiftCardSlipstreamFixture.make(
            storageDirectory: testTempDirectory,
            isTorEnabled: false
        )
        // The native offline policy returns max(latest checkpoint, resolved birthday + 1).
        // A requested birthday beyond bundled checkpoints resolves to their latest entry.
        await fixture.anchor.setResponse(SlipstreamRestoreAnchor(height: 4_460_001, treeState: nil))

        _ = try await fixture.synchronizer.prepare(
            with: fixture.card.seed.withBytes { $0 },
            walletBirthday: 4_470_000,
            name: "Gift card",
            keySource: nil
        )

        let calls = await fixture.anchor.calls
        let call = try XCTUnwrap(calls.first)
        XCTAssertTrue(call.isRestore)
        XCTAssertEqual(call.birthday, 4_460_000)
        XCTAssertEqual(call.fallbackCheckpointHeight, 4_460_000)
        let created = try XCTUnwrap(fixture.backend.createAccountSeedTreeStateRecoverUntilNameKeySourceReceivedArguments)
        XCTAssertEqual(created.treeState.height, 4_460_000)
        XCTAssertEqual(created.recoverUntil, 4_460_001)
    }
}
