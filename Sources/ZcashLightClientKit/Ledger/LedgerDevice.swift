//
//  LedgerDevice.swift
//  ZcashLightClientKit
//

import Foundation

/// The pairing and address commands of a Ledger device running the Zcash app, over its ``transport``.
///
/// Signing is done by `Synchronizer.signPCZTWithLedger(pczt:accountUUID:binding:transport:progress:)`,
/// which needs the wallet database.
///
/// Every method throws a ``ZcashError`` from the `ledger` family, or `CancellationError` when its task
/// is cancelled. A method whose exchange fails on the transport, or is cancelled, closes the
/// transport: open a new connection before trying again. Calls are serialized; a call made while
/// another is in progress waits for it.
///
/// The caller owns every transport: the one passed to `init` and every one a `pairAccount`
/// `reconnect` function returns. This closes a transport whose exchange failed (closing is idempotent)
/// but never closes one otherwise, so the caller closes each transport it opened, whether the call
/// succeeded or failed. ``transport`` is the one this device currently talks over; once `pairAccount`
/// has reconnected, it is the reconnected one, and later calls use it.
public actor LedgerDevice {
    /// The default for `pairAccount`'s `readTimeout`: the reads before the export answer at once on a
    /// healthy link, so a device silent this long is stalled. It is not the default value of
    /// `readTimeout` itself, which keeps the engine's normal timeout, like every other read.
    public static let defaultPairingReadTimeout: TimeInterval = 10

    /// The engine's normal timeout: every read but the export uses it by default, `pairAccount`'s
    /// `readTimeout` included. A separate, public mirror of the internal `ZcashLedgerBackend.defaultTimeout`,
    /// which a public default parameter value cannot reference directly.
    public static let defaultReadTimeout: TimeInterval = ZcashLedgerBackend.defaultTimeout

    /// The transport this device talks over: the one passed to `init`, or the last one a
    /// `pairAccount` `reconnect` function returned. The caller closes it; see the class documentation.
    public private(set) var transport: LedgerAPDUTransport
    private let networkType: NetworkType
    private let gate = LedgerSerialGate()

    /// - Parameters:
    ///   - transport: The connection to the device, such as a ``LedgerBluetoothTransport``.
    ///   - networkType: The network the wallet runs on. A device identity and every derivation path
    ///     depend on it. Regtest has no Ledger app build and is refused.
    public init(transport: LedgerAPDUTransport, networkType: NetworkType) {
        self.transport = transport
        self.networkType = networkType
    }

    /// Reads the version of the Zcash app the device is running.
    ///
    /// - Throws: ``ZcashError/ledgerWrongApp(_:)`` when the device is not running the Zcash app.
    public func appVersion() async throws -> LedgerAppVersion {
        try await serialized {
            try await self.readAppVersion()
        }
    }

    /// Reads the device's identity, silently: nothing is shown on the device.
    public func deviceIdentity() async throws -> LedgerDeviceIdentity {
        try await serialized {
            try await self.readDeviceIdentity()
        }
    }

    /// Exports the unified full viewing key of one account, for the wallet to import.
    ///
    /// The device asks the user to approve the export; no timeout applies while it waits. The
    /// device's identity is read once, before the export, and the pairing is refused unless the
    /// export comes back from that same device, so that the key and the binding can never come from
    /// two different devices; nothing is read after the export.
    ///
    /// The app-version and identity reads before the export each have `readTimeout`; nothing waits on
    /// the user there, so a device that does not answer within it is stalled. When one of them fails
    /// on the connection (``ZcashError/ledgerTimeout``, ``ZcashError/ledgerBluetoothDisconnected``,
    /// ``ZcashError/ledgerBluetoothConnectionFailed(_:)`` or ``ZcashError/ledgerDeviceNotFound``) and
    /// `reconnect` is given, the failed transport (already closed) is replaced with one from
    /// `reconnect`, and both reads are asked again from the start on it. A second such failure is
    /// final, and so is a refusal before the export. Nothing is retried once the export command has
    /// been sent.
    ///
    /// A transport `reconnect` returns becomes ``transport``, whatever the outcome, and belongs to the
    /// caller like the one passed to `init`; a failure `reconnect` itself throws propagates as it is.
    ///
    /// - Parameters:
    ///   - zip32AccountIndex: The account to export.
    ///   - readTimeout: How long each read before the export may take. Defaults to
    ///     ``defaultReadTimeout``, the timeout every other read uses; pass
    ///     ``defaultPairingReadTimeout`` to detect a stalled device early.
    ///   - reconnect: Opens a fresh connection to the same device, for one retry of the reads before
    ///     the export. `nil` for no retry.
    /// - Throws: ``ZcashError/ledgerAppTooOld(_:)`` when the app cannot sign transactions for this SDK,
    ///   ``ZcashError/ledgerUserRejected`` when the user declines the export,
    ///   ``ZcashError/ledgerDerivationBudgetExhausted`` when the user must reopen the Zcash app first.
    public func pairAccount(
        zip32AccountIndex: Zip32AccountIndex,
        readTimeout: TimeInterval = defaultReadTimeout,
        reconnect: (@Sendable () async throws -> any LedgerAPDUTransport)? = nil
    ) async throws -> LedgerAccountPairing {
        let networkType = self.networkType
        return try await serialized {
            let (appVersion, identity) = try await self.readBeforeExport(readTimeout: readTimeout, reconnect: reconnect)
            let encodedUFVK = try await self.exportUFVK(zip32AccountIndex: zip32AccountIndex)

            let ufvk: UnifiedFullViewingKey
            do {
                ufvk = try UnifiedFullViewingKey(encoding: encodedUFVK, network: networkType)
            } catch {
                throw ZcashError.ledgerMalformedReply("the exported viewing key is not a unified full viewing key for this network")
            }

            return LedgerAccountPairing(
                ufvk: ufvk,
                binding: LedgerAccountBinding(deviceIdentity: identity, zip32AccountIndex: zip32AccountIndex),
                appVersion: appVersion
            )
        }
    }

    /// Shows the account's unified address on the device for the user to compare, and returns the
    /// address the device displayed.
    ///
    /// The device's address holds only the account's Orchard receiver at diversifier index 0, whatever
    /// `transparentAddressIndex` is: the index selects the transparent address the device shows next to
    /// it. Compare the result with a unified address built from that single Orchard receiver; the
    /// account's default unified address also carries a transparent receiver and never matches.
    ///
    /// - Parameters:
    ///   - zip32AccountIndex: The account, at most 100 for this command.
    ///   - transparentAddressIndex: The external transparent address to show, at most 50000.
    /// - Throws: ``ZcashError/ledgerUserRejected`` when the user rejects the address on the device.
    public func displayUnifiedAddress(
        zip32AccountIndex: Zip32AccountIndex,
        transparentAddressIndex: UInt32
    ) async throws -> UnifiedAddress {
        let networkType = self.networkType
        return try await serialized {
            let apdu = try ZcashLedgerBackend.unifiedAddressAPDU(
                networkType: networkType,
                accountIndex: zip32AccountIndex,
                transparentAddressIndex: transparentAddressIndex,
                display: true
            )
            // The display waits on the user, so no timeout applies.
            let encoded = try await LedgerCommands.query(apdu, on: self.transport, timeout: nil) { reply in
                try ZcashLedgerBackend.parseUnifiedAddress(reply, networkType: networkType)
            }

            do {
                return try UnifiedAddress(encoding: encoded, network: networkType)
            } catch {
                throw ZcashError.ledgerMalformedReply("the displayed address is not a unified address for this network")
            }
        }
    }

    // MARK: - Commands

    /// The reads before the export, retried once over a transport from `reconnect` when the first
    /// attempt fails on the connection.
    private func readBeforeExport(
        readTimeout: TimeInterval,
        reconnect: (@Sendable () async throws -> any LedgerAPDUTransport)?
    ) async throws -> (LedgerAppVersion, LedgerDeviceIdentity) {
        do {
            return try await readAppVersionAndIdentity(timeout: readTimeout)
        } catch {
            guard let reconnect, isLinkFailure(error) else { throw error }
            transport = try await reconnect()
            return try await readAppVersionAndIdentity(timeout: readTimeout)
        }
    }

    private func readAppVersionAndIdentity(timeout: TimeInterval) async throws -> (LedgerAppVersion, LedgerDeviceIdentity) {
        let appVersion = try await readAppVersion(timeout: timeout)
        guard appVersion.supportsPczt else {
            throw ZcashError.ledgerAppTooOld("the Zcash app is v\(appVersion), which predates PCZT signing")
        }
        let identity = try await readDeviceIdentity(timeout: timeout)
        return (appVersion, identity)
    }

    private func readAppVersion(timeout: TimeInterval = ZcashLedgerBackend.defaultTimeout) async throws -> LedgerAppVersion {
        let apdu = try ZcashLedgerBackend.firmwareVersionAPDU()
        return try await LedgerCommands.query(
            apdu,
            on: transport,
            timeout: timeout,
            parse: ZcashLedgerBackend.parseAppVersion
        )
    }

    private func readDeviceIdentity(timeout: TimeInterval = ZcashLedgerBackend.defaultTimeout) async throws -> LedgerDeviceIdentity {
        let apdu = try ZcashLedgerBackend.deviceIdentityAPDU(networkType: networkType)
        return try await LedgerCommands.query(
            apdu,
            on: transport,
            timeout: timeout,
            parse: ZcashLedgerBackend.parseDeviceIdentity
        )
    }

    /// Runs the `GET_VK` exchange to completion. Its request waits on the user's approval.
    private func exportUFVK(zip32AccountIndex: Zip32AccountIndex) async throws -> String {
        let export = try LedgerUFVKExport(networkType: networkType, accountIndex: zip32AccountIndex)
        while true {
            let timeout: TimeInterval? = export.waitsForUser ? nil : ZcashLedgerBackend.defaultTimeout
            let apdu = try export.nextAPDU()
            let reply = try await LedgerCommands.exchange(apdu, on: transport, timeout: timeout)
            switch try export.processResponse(reply) {
            case .moreChunks:
                continue
            case .retrySameAPDU:
                try await LedgerCommands.backOff(transport: transport)
            case .complete(let ufvk):
                return ufvk
            }
        }
    }

    /// Runs `operation` once no other call on this device is in progress, and converts its failure into
    /// the public error.
    private func serialized<T>(_ operation: () async throws -> T) async throws -> T {
        await gate.acquire()
        do {
            let result = try await operation()
            await gate.release()
            return result
        } catch {
            await gate.release()
            throw ledgerZcashError(error)
        }
    }
}
