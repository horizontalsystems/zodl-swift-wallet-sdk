//
//  LedgerZcashApp.swift
//  ZcashLightClientKit
//

import Foundation

/// Brings a Ledger device to the Zcash app through the device's own dashboard commands, which answer
/// whatever app is running: which app is open, close it, open another one by name.
///
/// A device returns to its dashboard after a first Bluetooth pairing, and every Zcash command then
/// fails. ``ensureZcashAppOpen(transport:reconnect:)`` opens the Zcash app for the user, who confirms
/// it on the device, before ``LedgerDevice`` is used.
///
/// Nothing handled here is logged: not the commands, not the replies, not the app names.
public enum LedgerZcashApp {
    private static let queryTimeout: TimeInterval = 10
    private static let pollInterval: TimeInterval = 0.2
    private static let appTransitionTimeout: TimeInterval = 10

    /// Reads which app the device is running. Works on the dashboard and in any app.
    ///
    /// - Throws: ``ZcashError/ledgerDeviceRefused(_:_:)`` if the device refuses the query; a locked
    ///   device's refusal is transient. ``ZcashError/ledgerMalformedReply(_:)`` if the reply is not an
    ///   app name and version. A ``ZcashError`` for a transport failure.
    public static func currentApp(transport: any LedgerAPDUTransport) async throws -> LedgerRunningApp {
        try await launcher().currentApp(transport: transport)
    }

    /// Makes sure the device is running the Zcash app, opening it if needed, and returns the
    /// transport to keep using.
    ///
    /// If the Zcash app is already open, nothing is sent beyond the query and the transport it was
    /// answered on is returned. Otherwise any other app is closed, the device is asked to open the
    /// Zcash app — it asks the user to confirm, and the reply waits for that without a timeout — and
    /// the device is polled until it reports the Zcash app, for up to 10 seconds after the reply. The
    /// Bluetooth link may drop while the device switches apps; a dropped link is then replaced with a
    /// transport from `reconnect`, and the transport returned may be one of those.
    ///
    /// A transport this replaces is closed, whatever happens. The caller closes the one returned, and
    /// `transport` if the call fails; a transport opened through `reconnect` is closed here when the
    /// call fails.
    ///
    /// - Parameters:
    ///   - transport: A transport connected to the device.
    ///   - reconnect: Opens a new transport to the same device.
    /// - Throws: ``ZcashError/ledgerAppNotInstalled`` if the Zcash app is not installed.
    ///   ``ZcashError/ledgerAppOpenRejected`` if the user declines opening it on the device.
    ///   ``ZcashError/ledgerDeviceRefused(_:_:)`` if the device is locked (transient) or refuses a
    ///   command. ``ZcashError/ledgerWrongApp(_:)`` if the device does not reach the Zcash app in
    ///   time, or cannot open it; the user has to open it on the device. A ``ZcashError`` for any
    ///   other failure.
    public static func ensureZcashAppOpen(
        transport: any LedgerAPDUTransport,
        reconnect: @escaping @Sendable () async throws -> any LedgerAPDUTransport
    ) async throws -> any LedgerAPDUTransport {
        try await launcher().ensureZcashAppOpen(transport: transport, reconnect: reconnect)
    }

    private static func launcher() -> LedgerAppLauncher {
        LedgerAppLauncher(queryTimeout: queryTimeout, pollInterval: pollInterval, transitionTimeout: appTransitionTimeout)
    }
}

/// `LedgerZcashApp`'s orchestration, with its timings as parameters.
final class LedgerAppLauncher {
    // Not `private`: `AppSwitch` below, a separate sibling type in this same file, reads these two.
    let queryTimeout: TimeInterval
    let pollInterval: TimeInterval
    private let transitionTimeout: TimeInterval

    init(queryTimeout: TimeInterval, pollInterval: TimeInterval, transitionTimeout: TimeInterval) {
        self.queryTimeout = queryTimeout
        self.pollInterval = pollInterval
        self.transitionTimeout = transitionTimeout
    }

    func currentApp(transport: any LedgerAPDUTransport) async throws -> LedgerRunningApp {
        let reply = try await transport.exchange(getAppAndVersionAPDU(), timeout: queryTimeout)
        let bytes = [UInt8](reply)
        let statusWord = try dashboardStatusWord(bytes)
        guard statusWord == swOK else {
            throw dashboardRefusal(statusWord)
        }
        return try parseRunningApp(bytes)
    }

    /// Makes sure the device is running the Zcash app; see `LedgerZcashApp.ensureZcashAppOpen(transport:reconnect:)`.
    ///
    /// The first query is a plain query on `transport`: no retry on a fresh connection.
    func ensureZcashAppOpen(
        transport: any LedgerAPDUTransport,
        reconnect: @escaping @Sendable () async throws -> any LedgerAPDUTransport
    ) async throws -> any LedgerAPDUTransport {
        let appSwitch = AppSwitch(original: transport, reconnect: reconnect, launcher: self)
        do {
            let running = try await currentApp(transport: transport)
            if running.isZcash {
                return appSwitch.current
            }
            if !running.isDashboard {
                try await appSwitch.closeRunningApp()
                try await appSwitch.awaitApp(deadline: transitionDeadline()) { $0.isDashboard }
            }
            try await appSwitch.openZcashApp()
            try await appSwitch.awaitApp(deadline: transitionDeadline()) { $0.isZcash }
            return appSwitch.current
        } catch {
            await appSwitch.closeReplacement()
            throw error
        }
    }

    private func transitionDeadline() -> DispatchTime {
        DispatchTime.now() + transitionTimeout
    }
}

/// The transport through an app switch that `LedgerAppLauncher.ensureZcashAppOpen(transport:reconnect:)`
/// drives: `current` is the caller's transport until a dropped link is replaced with one from
/// `reconnect`.
private final class AppSwitch {
    private let original: any LedgerAPDUTransport
    private let reconnect: @Sendable () async throws -> any LedgerAPDUTransport
    private let launcher: LedgerAppLauncher

    private(set) var current: any LedgerAPDUTransport
    private var usable = true
    private var didReplaceTransport = false

    init(
        original: any LedgerAPDUTransport,
        reconnect: @escaping @Sendable () async throws -> any LedgerAPDUTransport,
        launcher: LedgerAppLauncher
    ) {
        self.original = original
        self.reconnect = reconnect
        self.launcher = launcher
        self.current = original
    }

    func closeRunningApp() async throws {
        guard let reply = try await exchangeAllowingDisconnect(closeAppAPDU(), timeout: launcher.queryTimeout) else {
            return
        }

        let statusWord = try dashboardStatusWord([UInt8](reply))
        guard statusWord == swOK else {
            throw dashboardRefusal(statusWord)
        }
    }

    func openZcashApp() async throws {
        guard let reply = try await exchangeAllowingDisconnect(openZcashAppAPDU(), timeout: nil) else {
            return
        }

        if let failure = openFailure(try dashboardStatusWord([UInt8](reply))) {
            throw failure
        }
    }

    /// Polls the device, reconnecting when the link is down, until it runs an app `reached` accepts.
    /// The deadline is checked between attempts.
    func awaitApp(deadline: DispatchTime, reached: (LedgerRunningApp) -> Bool) async throws {
        while true {
            if try await poll(reached: reached) {
                return
            }
            if DispatchTime.now() >= deadline {
                throw ZcashError.ledgerWrongApp(0)
            }
            try await Task.sleep(nanoseconds: UInt64(launcher.pollInterval * 1_000_000_000))
        }
    }

    private func poll(reached: (LedgerRunningApp) -> Bool) async throws -> Bool {
        let running: LedgerRunningApp?
        if usable {
            running = try await queryAllowingDisconnect()
        } else if try await replace() {
            running = try await queryAllowingDisconnect()
        } else {
            running = nil
        }
        return running.map(reached) ?? false
    }

    /// The running app, or `nil` if the link dropped.
    private func queryAllowingDisconnect() async throws -> LedgerRunningApp? {
        do {
            return try await launcher.currentApp(transport: current)
        } catch {
            guard isLinkFailure(error) else { throw error }
            await markUnusable()
            return nil
        }
    }

    /// Replaces the dropped transport with a new one; `false` if the device cannot be reached yet.
    private func replace() async throws -> Bool {
        let replacement: any LedgerAPDUTransport
        do {
            replacement = try await reconnect()
        } catch {
            guard isLinkFailure(error) else { throw error }
            return false
        }

        await closeQuietly(current)
        current = replacement
        didReplaceTransport = true
        usable = true
        return true
    }

    private func exchangeAllowingDisconnect(_ apdu: Data, timeout: TimeInterval?) async throws -> Data? {
        do {
            return try await current.exchange(apdu, timeout: timeout)
        } catch {
            guard isLinkFailure(error) else { throw error }
            await markUnusable()
            return nil
        }
    }

    private func markUnusable() async {
        usable = false
        await closeQuietly(current)
    }

    func closeReplacement() async {
        guard didReplaceTransport else { return }
        await closeQuietly(current)
    }
}

// MARK: - Dashboard protocol

private let swOK: UInt16 = 0x9000
private let swUserRefused: UInt16 = 0x5501
private let swLocked: UInt16 = 0x5515
private let swAppNotInstalled: UInt16 = 0x6807

private func getAppAndVersionAPDU() -> Data {
    Data([0xB0, 0x01, 0x00, 0x00, 0x00])
}

private func closeAppAPDU() -> Data {
    Data([0xB0, 0xA7, 0x00, 0x00, 0x00])
}

private func openZcashAppAPDU() -> Data {
    let name = Data(LedgerRunningApp.zcashAppName.utf8)
    return Data([0xE0, 0xD8, 0x00, 0x00, UInt8(name.count)]) + name
}

private func dashboardStatusWord(_ reply: [UInt8]) throws -> UInt16 {
    guard reply.count >= 2 else {
        throw ZcashError.ledgerMalformedReply("the device's reply has no status word")
    }
    return UInt16(reply[reply.count - 2]) << 8 | UInt16(reply[reply.count - 1])
}

/// Parses `format ‖ nameLen ‖ name ‖ versionLen ‖ version ‖ [flagsLen ‖ flags]` followed by the status
/// word. Trailing flags are not read.
private func parseRunningApp(_ reply: [UInt8]) throws -> LedgerRunningApp {
    let end = reply.count - 2
    var cursor = 0

    func malformed() -> ZcashError {
        .ledgerMalformedReply("the device's app query reply is malformed")
    }

    func readField() throws -> String {
        guard cursor < end else { throw malformed() }
        let length = Int(reply[cursor])
        let start = cursor + 1
        guard start + length <= end else { throw malformed() }
        cursor = start + length
        return String(decoding: reply[start..<start + length], as: UTF8.self)
    }

    guard end >= 1, reply[cursor] == 0x01 else { throw malformed() }
    cursor += 1
    let name = try readField()
    let version = try readField()
    return LedgerRunningApp(name: name, version: version)
}

/// The locked-device refusal as the Ledger engine reports it: transient. Any other status word
/// reaching here is final.
private func dashboardRefusal(_ statusWord: UInt16) -> ZcashError {
    .ledgerDeviceRefused(statusWord, statusWord == swLocked)
}

/// What an answer to the open command means: nothing to raise when the device is opening the app,
/// else the failure.
private func openFailure(_ statusWord: UInt16) -> ZcashError? {
    switch statusWord {
    case swOK:
        return nil
    case swUserRefused:
        return .ledgerAppOpenRejected
    case swAppNotInstalled:
        return .ledgerAppNotInstalled
    case swLocked:
        return dashboardRefusal(statusWord)
    default:
        return .ledgerWrongApp(statusWord)
    }
}

/// A failure of the link rather than an answer from the device: expected while it switches apps.
private func isLinkFailure(_ error: Error) -> Bool {
    guard let zcashError = error as? ZcashError else { return false }
    switch zcashError {
    case .ledgerBluetoothDisconnected, .ledgerTimeout, .ledgerBluetoothConnectionFailed, .ledgerDeviceNotFound:
        return true
    default:
        return false
    }
}

private func closeQuietly(_ transport: any LedgerAPDUTransport) async {
    await transport.close()
}
