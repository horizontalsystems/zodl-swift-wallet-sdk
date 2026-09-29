//
//  LedgerZcashAppTests.swift
//  OfflineTests
//
//  `LedgerAppLauncher`, driven through `ScriptedLedgerTransport` with small timings so the polling
//  and transition-timeout paths run quickly.
//

import XCTest
@testable import ZcashLightClientKit

// MARK: - Fixtures

private let getAppAPDU = Data([0xB0, 0x01, 0x00, 0x00, 0x00])
private let closeAppAPDU = Data([0xB0, 0xA7, 0x00, 0x00, 0x00])
private let openZcashAPDU = Data([0xE0, 0xD8, 0x00, 0x00, 0x05]) + Data("Zcash".utf8)

/// An app-query reply: `format ‖ nameLen ‖ name ‖ versionLen ‖ version ‖ [flagsLen ‖ flags] ‖ SW`.
private func app(_ name: String, version: String = "1.0.0", flags: [UInt8]? = nil) -> Data {
    var reply = Data([0x01, UInt8(name.utf8.count)])
    reply.append(Data(name.utf8))
    reply.append(UInt8(version.utf8.count))
    reply.append(Data(version.utf8))
    if let flags {
        reply.append(UInt8(flags.count))
        reply.append(Data(flags))
    }
    reply.append(LedgerReplies.status(0x9000))
    return reply
}

private let dashboardReply = app("BOLOS", version: "2.2.3", flags: [0x02])
private let zcashReply = app("Zcash", version: "4.2.0")

/// A transport that answers each call with the next reply in `replies`, in order.
private func scripted(_ replies: [Data]) -> ScriptedLedgerTransport {
    ScriptedLedgerTransport { _, history in replies[history.count] }
}

private struct UnexpectedReconnect: Error {}

/// A `reconnect` that fails the test if it is ever called.
private func noReconnect() -> @Sendable () async throws -> any LedgerAPDUTransport {
    { throw UnexpectedReconnect() }
}

private func isSame(_ lhs: any LedgerAPDUTransport, _ rhs: any LedgerAPDUTransport) -> Bool {
    (lhs as AnyObject) === (rhs as AnyObject)
}

/// Counts calls from a `@Sendable` closure, such as a `reconnect` callback.
private actor CallCounter {
    private(set) var count = 0

    @discardableResult
    func increment() -> Int {
        count += 1
        return count
    }
}

// MARK: - Tests

final class LedgerZcashAppTests: XCTestCase {
    private let queryTimeout: TimeInterval = 5
    private let pollInterval: TimeInterval = 0.001
    private let transitionTimeout: TimeInterval = 0.2

    private lazy var launcher = LedgerAppLauncher(queryTimeout: queryTimeout, pollInterval: pollInterval, transitionTimeout: transitionTimeout)

    // MARK: currentApp

    func testTheAppQueryIsParsed() async throws {
        let transport = scripted([dashboardReply])

        let running = try await launcher.currentApp(transport: transport)

        XCTAssertEqual(running.name, "BOLOS")
        XCTAssertEqual(running.version, "2.2.3")
        XCTAssertTrue(running.isDashboard)
        XCTAssertFalse(running.isZcash)
        let received = await transport.received
        XCTAssertEqual(received, [getAppAPDU])
        let timeouts = await transport.timeouts
        XCTAssertEqual(timeouts, [queryTimeout])
    }

    func testEveryDashboardNameIsRecognized() async throws {
        for name in ["BOLOS", "OLOS", "OLOS\u{0}"] {
            let running = try await launcher.currentApp(transport: scripted([app(name)]))
            XCTAssertTrue(running.isDashboard, name)
        }
    }

    func testAMalformedAppQueryReplyIsRefused() async throws {
        let malformed: [Data] = [
            LedgerReplies.status(0x9000),
            Data([0x90]),
            Data([0x02, 0x01, 0x5A, 0x00]) + LedgerReplies.status(0x9000),
            Data([0x01, 0x09, 0x5A]) + LedgerReplies.status(0x9000),
            Data([0x01, 0x01, 0x5A]) + LedgerReplies.status(0x9000),
            Data([0x01, 0x01, 0x5A, 0x04, 0x31]) + LedgerReplies.status(0x9000)
        ]

        for (index, reply) in malformed.enumerated() {
            do {
                _ = try await launcher.currentApp(transport: scripted([reply]))
                XCTFail("reply \(index) must be refused as malformed")
            } catch let error as ZcashError {
                guard case .ledgerMalformedReply = error else {
                    return XCTFail("Unexpected error \(error.code) for reply \(index)")
                }
            }
        }
    }

    func testALockedDeviceRefusesTheAppQueryTransiently() async throws {
        do {
            _ = try await launcher.currentApp(transport: scripted([LedgerReplies.status(0x5515)]))
            XCTFail("A locked device must refuse the query")
        } catch let error as ZcashError {
            guard case let .ledgerDeviceRefused(statusWord, isTransient) = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
            XCTAssertEqual(statusWord, 0x5515)
            XCTAssertTrue(isTransient)
            XCTAssertEqual(error.ledgerIsRestartable, true)
        }
    }

    // MARK: ensureZcashAppOpen

    func testAnOpenZcashAppIsLeftAlone() async throws {
        let transport = scripted([zcashReply])

        let result = try await launcher.ensureZcashAppOpen(transport: transport, reconnect: noReconnect())

        XCTAssertTrue(isSame(result, transport))
        let received = await transport.received
        XCTAssertEqual(received.count, 1, "no open command is sent")
        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 0)
    }

    func testTheDashboardOpensTheZcashAppAndPollsUntilItRuns() async throws {
        let transport = scripted([dashboardReply, LedgerReplies.status(0x9000), dashboardReply, dashboardReply, zcashReply])

        let result = try await launcher.ensureZcashAppOpen(transport: transport, reconnect: noReconnect())

        XCTAssertTrue(isSame(result, transport))
        let received = await transport.received
        XCTAssertEqual(received.count, 5)
        XCTAssertEqual(received[0], getAppAPDU)
        XCTAssertEqual(received[1], openZcashAPDU)
        let timeouts = await transport.timeouts
        XCTAssertNil(timeouts[1], "opening waits on the user")
        for command in received[2...] {
            XCTAssertEqual(command, getAppAPDU)
        }
        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 0)
    }

    func testAnotherAppIsClosedBeforeTheZcashAppIsOpened() async throws {
        let transport = scripted([
            app("Bitcoin"), LedgerReplies.status(0x9000), app("Bitcoin"), dashboardReply, LedgerReplies.status(0x9000), zcashReply
        ])

        let result = try await launcher.ensureZcashAppOpen(transport: transport, reconnect: noReconnect())

        XCTAssertTrue(isSame(result, transport))
        let expected = [getAppAPDU, closeAppAPDU, getAppAPDU, getAppAPDU, openZcashAPDU, getAppAPDU]
        let received = await transport.received
        XCTAssertEqual(received, expected)
    }

    func testALinkDroppedWhileOpeningIsReconnectedAndPolled() async throws {
        let original = ScriptedLedgerTransport { _, history in
            if history.count == 1 { throw ZcashError.ledgerBluetoothDisconnected }
            return dashboardReply
        }
        let afterSwitch = scripted([dashboardReply, zcashReply])
        let reconnects = CallCounter()

        let result = try await launcher.ensureZcashAppOpen(transport: original) {
            let count = await reconnects.increment()
            if count == 1 { throw ZcashError.ledgerBluetoothConnectionFailed(nil) }
            return afterSwitch
        }

        XCTAssertTrue(isSame(result, afterSwitch))
        let reconnectCount = await reconnects.count
        XCTAssertEqual(reconnectCount, 2)
        let originalReceived = await original.received
        XCTAssertEqual(originalReceived[1], openZcashAPDU)
        let originalCloseCount = await original.closeCount
        XCTAssertGreaterThan(originalCloseCount, 0, "the replaced transport is closed")
        let afterSwitchCloseCount = await afterSwitch.closeCount
        XCTAssertEqual(afterSwitchCloseCount, 0)
        let afterSwitchReceived = await afterSwitch.received
        XCTAssertEqual(afterSwitchReceived.count, 2)
    }

    func testALinkDroppedWhilePollingIsReconnected() async throws {
        let original = ScriptedLedgerTransport { _, history in
            if history.count == 2 { throw ZcashError.ledgerTimeout }
            return history.isEmpty ? dashboardReply : LedgerReplies.status(0x9000)
        }
        let afterSwitch = scripted([zcashReply])

        let result = try await launcher.ensureZcashAppOpen(transport: original) { afterSwitch }

        XCTAssertTrue(isSame(result, afterSwitch))
        let originalCloseCount = await original.closeCount
        XCTAssertGreaterThan(originalCloseCount, 0)
    }

    func testDecliningToOpenTheAppIsRestartable() async throws {
        let transport = scripted([dashboardReply, LedgerReplies.status(0x5501)])

        do {
            _ = try await launcher.ensureZcashAppOpen(transport: transport, reconnect: noReconnect())
            XCTFail("Declining to open the app must fail")
        } catch let error as ZcashError {
            guard case .ledgerAppOpenRejected = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
            XCTAssertEqual(error.ledgerIsRestartable, true)
        }

        let received = await transport.received
        XCTAssertEqual(received.count, 2)
    }

    func testAMissingZcashAppIsReported() async throws {
        let transport = scripted([dashboardReply, LedgerReplies.status(0x6807)])

        do {
            _ = try await launcher.ensureZcashAppOpen(transport: transport, reconnect: noReconnect())
            XCTFail("A missing Zcash app must fail")
        } catch let error as ZcashError {
            guard case .ledgerAppNotInstalled = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
            XCTAssertEqual(error.ledgerIsRestartable, false)
        }
    }

    func testADeviceLockedWhileOpeningIsATransientRefusal() async throws {
        let transport = scripted([dashboardReply, LedgerReplies.status(0x5515)])

        do {
            _ = try await launcher.ensureZcashAppOpen(transport: transport, reconnect: noReconnect())
            XCTFail("A locked device must fail")
        } catch let error as ZcashError {
            guard case let .ledgerDeviceRefused(statusWord, isTransient) = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
            XCTAssertEqual(statusWord, 0x5515)
            XCTAssertTrue(isTransient)
        }
    }

    func testAnUnknownRefusalToOpenAsksForTheZcashApp() async throws {
        let transport = scripted([dashboardReply, LedgerReplies.status(0x6D00)])

        do {
            _ = try await launcher.ensureZcashAppOpen(transport: transport, reconnect: noReconnect())
            XCTFail("An unknown refusal must fail")
        } catch let error as ZcashError {
            guard case let .ledgerWrongApp(statusWord) = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
            XCTAssertEqual(statusWord, 0x6D00)
        }
    }

    func testADeviceThatNeverReachesTheZcashAppTimesOut() async throws {
        let openAck = LedgerReplies.status(0x9000)
        let transport = ScriptedLedgerTransport { _, history in
            history.count == 1 ? openAck : dashboardReply
        }

        do {
            _ = try await launcher.ensureZcashAppOpen(transport: transport, reconnect: noReconnect())
            XCTFail("A device that never switches apps must time out")
        } catch let error as ZcashError {
            guard case let .ledgerWrongApp(statusWord) = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
            XCTAssertEqual(statusWord, 0)
        }

        let received = await transport.received
        XCTAssertGreaterThan(received.count, 3, "the device was polled")
    }

    func testAReconnectedTransportIsClosedWhenTheSwitchTimesOut() async throws {
        let original = ScriptedLedgerTransport { _, history in
            if history.count == 1 { throw ZcashError.ledgerBluetoothDisconnected }
            return dashboardReply
        }
        let replacement = ScriptedLedgerTransport { _, _ in dashboardReply }

        do {
            _ = try await launcher.ensureZcashAppOpen(transport: original) { replacement }
            XCTFail("A switch that never reaches the Zcash app must time out")
        } catch let error as ZcashError {
            guard case .ledgerWrongApp = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
        }

        let originalCloseCount = await original.closeCount
        XCTAssertGreaterThan(originalCloseCount, 0)
        let replacementCloseCount = await replacement.closeCount
        XCTAssertGreaterThan(replacementCloseCount, 0)
    }

    func testAFatalReconnectFailurePropagates() async throws {
        let original = ScriptedLedgerTransport { _, history in
            if history.count == 1 { throw ZcashError.ledgerBluetoothDisconnected }
            return dashboardReply
        }

        do {
            _ = try await launcher.ensureZcashAppOpen(transport: original) {
                throw ZcashError.ledgerBluetoothPoweredOff
            }
            XCTFail("A fatal reconnect failure must propagate")
        } catch let error as ZcashError {
            guard case .ledgerBluetoothPoweredOff = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
        }
    }

    // MARK: First-query retry

    func testAStalledFirstQueryIsAskedOnceMoreOnAFreshConnection() async throws {
        let stalled = ScriptedLedgerTransport { _, _ in throw ZcashError.ledgerTimeout }
        let fresh = scripted([zcashReply])
        let reconnects = CallCounter()

        let result = try await launcher.ensureZcashAppOpen(transport: stalled) {
            await reconnects.increment()
            return fresh
        }

        XCTAssertTrue(isSame(result, fresh))
        let reconnectCount = await reconnects.count
        XCTAssertEqual(reconnectCount, 1)
        let stalledCloseCount = await stalled.closeCount
        XCTAssertGreaterThan(stalledCloseCount, 0, "the stalled transport is closed")
        let freshReceived = await fresh.received
        XCTAssertEqual(freshReceived, [getAppAPDU])
    }

    func testAFirstQueryThatStallsTwiceFailsWithoutSendingAnythingElse() async throws {
        let stalled = ScriptedLedgerTransport { _, _ in throw ZcashError.ledgerTimeout }
        let stalledAgain = ScriptedLedgerTransport { _, _ in throw ZcashError.ledgerTimeout }
        let reconnects = CallCounter()

        do {
            _ = try await launcher.ensureZcashAppOpen(transport: stalled) {
                await reconnects.increment()
                return stalledAgain
            }
            XCTFail("A first query that stalls twice must fail")
        } catch let error as ZcashError {
            guard case .ledgerTimeout = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
        }

        let reconnectCount = await reconnects.count
        XCTAssertEqual(reconnectCount, 1)
        let stalledAgainReceived = await stalledAgain.received
        XCTAssertEqual(stalledAgainReceived.count, 1)
        let stalledAgainCloseCount = await stalledAgain.closeCount
        XCTAssertGreaterThan(stalledAgainCloseCount, 0, "the fresh transport is closed when the call fails")
    }

    func testALockedDeviceIsNotRetriedOnAFreshConnection() async throws {
        let locked = scripted([LedgerReplies.status(0x5515)])

        do {
            _ = try await launcher.ensureZcashAppOpen(transport: locked, reconnect: noReconnect())
            XCTFail("A locked device must fail without a retry")
        } catch let error as ZcashError {
            guard case .ledgerDeviceRefused = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
        }
    }
}
