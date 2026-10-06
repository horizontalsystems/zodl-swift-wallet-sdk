//
//  LedgerSerialGateTests.swift
//  OfflineTests
//
//  LedgerSerialGate, and the two callers that bracket their operation with it.
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class LedgerSerialGateTests: XCTestCase {
    /// A caller cancelled while only queued for the gate throws promptly, instead of being admitted
    /// later and failing inside its own operation. Arrival order for everyone else keeps working: the
    /// third caller is admitted as soon as the holder releases, right behind the (now gone) second.
    func testACancelledWaiterLeavesPromptlyAndArrivalOrderContinues() async throws {
        let gate = LedgerSerialGate()
        try await gate.acquire() // the holder

        let second = Task { try await gate.acquire() }
        second.cancel()

        do {
            try await second.value
            XCTFail("a cancelled waiter must throw")
        } catch is CancellationError {
            // expected
        }

        let third = Task { try await gate.acquire() }
        // A test-side backstop: if a bug left the gate unable to admit `third`, this cuts the test off
        // instead of hanging the whole run.
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            third.cancel()
        }

        await gate.release()

        do {
            try await third.value
        } catch {
            XCTFail("a third caller must be admitted once the holder releases: \(error)")
        }
        watchdog.cancel()
    }

    /// The reviewer's scenario: `acquire()` used to park a non-throwing continuation, so a caller
    /// cancelled while queued stayed queued, was eventually admitted anyway, and then failed inside
    /// its operation on `Task.checkCancellation()` -- closing the shared transport out from under
    /// whichever call was really in flight. A caller that throws out of `acquire()` itself never held
    /// the gate, so it must not reach that failure path at all.
    func testATransportIsNotClosedByACallerCancelledWhileWaitingForTheGate() async throws {
        let transport = ScriptedLedgerTransport(delayNanoseconds: 500_000_000) { _, _ in
            LedgerReplies.firmwareVersion(3, 9, 3)
        }
        let ledger = LedgerDevice(transport: transport, networkType: .testnet)

        let first = Task { try await ledger.appVersion() }
        // Lets `first` actually acquire the gate and reach its (stalled) exchange before a second
        // caller queues behind it.
        try await Task.sleep(nanoseconds: 50_000_000)

        let second = Task { try await ledger.appVersion() }
        try await Task.sleep(nanoseconds: 100_000_000)
        second.cancel()

        do {
            try await second.value
            XCTFail("a cancelled waiter must throw")
        } catch is CancellationError {
            // expected
        }

        let version = try await first.value
        XCTAssertEqual(version.description, "3.9.3", "the holder's own call must still complete normally")

        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 0, "a caller cancelled while only queued for the gate must not close the transport")
    }
}
