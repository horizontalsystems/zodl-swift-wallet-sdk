//
//  LedgerReconnectCeremonyTests.swift
//  OfflineTests
//
//  A pairing that reconnects partway through keeps its ceremony on the reconnected transport: nothing
//  else may run on the device, or on that transport, until the pairing itself is over.
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

/// Polls `condition` with a short yield between checks, failing the test after `timeoutSeconds` if
/// it never becomes true. Not named `waitUntil`: `XCTestCase` has a member of that name (from
/// `TestUtils`) that returns the outcome instead of failing, and member lookup would win.
private func expectEventually(
    timeoutSeconds: TimeInterval = 2,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () async -> Bool
) async {
    let deadline = DispatchTime.now() + timeoutSeconds
    while DispatchTime.now() < deadline {
        if await condition() {
            return
        }
        await Task.yield()
    }
    XCTFail("condition did not become true within \(timeoutSeconds) s", file: file, line: line)
}

/// A transport that answers the firmware-version and identity reads from a script, and on its first
/// `GET_VK` reply waits for ``releaseExport()`` instead of answering at once -- standing in for the
/// device waiting on the user's on-device approval of the export, which has no timeout of its own.
/// Later `GET_VK` chunks, once that first one is released, answer without waiting again.
private actor SignaledExportTransport: LedgerAPDUTransport {
    private(set) var received: [Data] = []
    private(set) var closeCount = 0
    private(set) var isWaitingForExportSignal = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var released = false
    private let chunks: [Data]

    init(ufvk: String) {
        self.chunks = LedgerReplies.viewingKeyChunks(ufvk)
    }

    var instructions: [UInt8] { received.map { $0[1] } }

    func exchange(_ apdu: Data, timeout: TimeInterval?) async throws -> Data {
        let history = received
        received.append(apdu)
        switch apdu[1] {
        case LedgerReplies.getFirmwareVersion:
            return LedgerReplies.firmwareVersion(3, 9, 3)
        case LedgerReplies.getWalletPublicKey:
            return LedgerReplies.walletPublicKey(LedgerReplies.seedIdentityPoint)
        case LedgerReplies.getVK:
            if !released {
                isWaitingForExportSignal = true
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    releaseContinuation = continuation
                }
                isWaitingForExportSignal = false
            }
            return chunks[history.filter { $0[1] == LedgerReplies.getVK }.count]
        default:
            return LedgerReplies.status(0x6D00)
        }
    }

    func close() async {
        closeCount += 1
    }

    /// Lets a `GET_VK` reply waiting in `exchange(_:timeout:)` proceed; every export chunk after it
    /// answers at once.
    func releaseExport() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

final class LedgerReconnectCeremonyTests: XCTestCase {
    private func testnetUFVK() throws -> UnifiedFullViewingKey {
        let tool = DerivationTool(networkType: .testnet)
        let usk = try tool.deriveUnifiedSpendingKey(seed: Environment.seedBytes, accountIndex: Zip32AccountIndex(0))
        return try tool.deriveUnifiedFullViewingKey(from: usk)
    }

    /// A transport whose every exchange fails on the connection, as if the device were out of range:
    /// `pairAccount`'s first read never gets further than this.
    private func stalledTransport() -> ScriptedLedgerTransport {
        ScriptedLedgerTransport { _, _ in throw ZcashError.ledgerTimeout }
    }

    /// The instructions a pairing of account 0 sends on the transport it ends up exporting over, then
    /// the one probe command after it, in order.
    private func pairingThenProbeInstructions(ufvk: String) -> [UInt8] {
        [LedgerReplies.getFirmwareVersion, LedgerReplies.getWalletPublicKey]
            + Array(repeating: LedgerReplies.getVK, count: LedgerReplies.viewingKeyChunks(ufvk).count)
            + [LedgerReplies.getFirmwareVersion]
    }

    // MARK: - A call on the same device waits for a reconnected export

    /// While a reconnected pairing's export waits on the device, a second call on the same
    /// `LedgerDevice` must not put its command on the reconnected transport until the pairing is over:
    /// its probe comes after every one of the export's chunks, never between two of them.
    func testAVersionProbeOnTheSameDeviceWaitsForAReconnectedExportToFinish() async throws {
        let ufvk = try testnetUFVK()
        let stalled = stalledTransport()
        let fresh = SignaledExportTransport(ufvk: ufvk.stringEncoded)
        let ledger = LedgerDevice(transport: stalled, networkType: .testnet)

        let pairing = Task {
            try await ledger.pairAccount(zip32AccountIndex: Zip32AccountIndex(0), reconnect: { fresh })
        }
        // Waits for the export to have actually reached its signal, so it provably holds the
        // reconnected transport's ceremony once the probe below is dispatched.
        await expectEventually { await fresh.isWaitingForExportSignal }

        let probe = Task { try await ledger.appVersion() }
        // Waits for the probe to have actually queued behind the pairing on this device, so
        // releasing the export next provably races a caller that is really waiting, not one that
        // simply has not been scheduled yet.
        await expectEventually { await ledger.queuedCount == 1 }

        await fresh.releaseExport()

        let pairingResult = try await pairing.value
        XCTAssertEqual(pairingResult.ufvk, ufvk)
        let probeVersion = try await probe.value
        XCTAssertEqual(probeVersion.description, "3.9.3")

        let instructions = await fresh.instructions
        XCTAssertEqual(
            instructions,
            pairingThenProbeInstructions(ufvk: ufvk.stringEncoded),
            "the export's chunks stay contiguous on the reconnected transport, and the probe comes after every one of them"
        )
        let stalledCloseCount = await stalled.closeCount
        XCTAssertEqual(stalledCloseCount, 1, "the stalled transport is closed once the read retries on a fresh connection")
        let freshCloseCount = await fresh.closeCount
        XCTAssertEqual(freshCloseCount, 0, "the caller closes the reconnected transport")
    }

    /// The same setup, but the queued probe is cancelled instead of completing: the pairing still
    /// finishes, and the reconnected transport is never closed over a call that never reached it.
    func testACallCancelledWhileQueuedBehindAReconnectedExportClosesNothing() async throws {
        let ufvk = try testnetUFVK()
        let stalled = stalledTransport()
        let fresh = SignaledExportTransport(ufvk: ufvk.stringEncoded)
        let ledger = LedgerDevice(transport: stalled, networkType: .testnet)

        let pairing = Task {
            try await ledger.pairAccount(zip32AccountIndex: Zip32AccountIndex(0), reconnect: { fresh })
        }
        await expectEventually { await fresh.isWaitingForExportSignal }

        let probe = Task { try await ledger.appVersion() }
        // Waits for the probe to have actually queued before cancelling it: cancelling any earlier
        // would exercise the already-cancelled-on-entry path instead of the queued one this test
        // means to cover.
        await expectEventually { await ledger.queuedCount == 1 }
        probe.cancel()

        do {
            _ = try await probe.value
            XCTFail("a call cancelled while queued must fail")
        } catch is CancellationError {
            // Expected.
        }

        await fresh.releaseExport()
        let pairingResult = try await pairing.value
        XCTAssertEqual(pairingResult.ufvk, ufvk)

        let freshCloseCount = await fresh.closeCount
        XCTAssertEqual(freshCloseCount, 0, "a call cancelled while only queued for its turn closes nothing")
    }

    // MARK: - A second device over the reconnected transport waits too

    /// A second `LedgerDevice` built directly over the reconnected transport waits for the pairing the
    /// same way a second call on the same device does. The per-device gate cannot be what stops it,
    /// since this is a different instance with its own, uncontended one; only the reconnected
    /// transport's own ceremony does.
    func testASecondDeviceOverTheReconnectedTransportWaitsForThePairingToFinish() async throws {
        let ufvk = try testnetUFVK()
        let stalled = stalledTransport()
        let fresh = SignaledExportTransport(ufvk: ufvk.stringEncoded)
        let ledger = LedgerDevice(transport: stalled, networkType: .testnet)

        let pairing = Task {
            try await ledger.pairAccount(zip32AccountIndex: Zip32AccountIndex(0), reconnect: { fresh })
        }
        await expectEventually { await fresh.isWaitingForExportSignal }

        let second = LedgerDevice(transport: fresh, networkType: .testnet)
        let probe = Task { try await second.appVersion() }
        // Waits for the second device's call to have actually queued on the reconnected transport's
        // own ceremony gate before releasing the export.
        await expectEventually { await LedgerCeremonyGates.shared.queuedCeremonies(on: fresh) == 1 }

        await fresh.releaseExport()

        let pairingResult = try await pairing.value
        XCTAssertEqual(pairingResult.ufvk, ufvk)
        let probeVersion = try await probe.value
        XCTAssertEqual(probeVersion.description, "3.9.3")

        let instructions = await fresh.instructions
        XCTAssertEqual(
            instructions,
            pairingThenProbeInstructions(ufvk: ufvk.stringEncoded),
            "the second device's probe comes after every command of the pairing on the reconnected transport"
        )
    }
}
