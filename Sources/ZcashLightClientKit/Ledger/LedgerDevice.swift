//
//  LedgerDevice.swift
//  ZcashLightClientKit
//

import Foundation

/// The pairing and address commands of a Ledger device running the Zcash app, over one transport.
///
/// Signing is done by `Synchronizer.signPCZTWithLedger(pczt:accountUUID:binding:transport:progress:)`,
/// which needs the wallet database.
///
/// Every method throws a ``ZcashError`` from the `ledger` family, or `CancellationError` when its task
/// is cancelled. A method whose exchange fails on the transport, or is cancelled, closes the
/// transport: open a new connection before trying again. Calls are serialized; a call made while
/// another is in progress waits for it.
public actor LedgerDevice {
    private let transport: LedgerAPDUTransport
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
    /// The device asks the user to approve the export; no timeout applies while it waits. The device's
    /// identity is read before and after the export, and the pairing is refused unless both reads
    /// name the same device, so that the key and the binding can never come from two different
    /// devices.
    ///
    /// - Parameter zip32AccountIndex: The account to export.
    /// - Throws: ``ZcashError/ledgerAppTooOld(_:)`` when the app cannot sign transactions for this SDK,
    ///   ``ZcashError/ledgerUserRejected`` when the user declines the export,
    ///   ``ZcashError/ledgerDeviceMismatch`` when the identity changes across the export,
    ///   ``ZcashError/ledgerDerivationBudgetExhausted`` when the user must reopen the Zcash app first.
    public func pairAccount(zip32AccountIndex: Zip32AccountIndex) async throws -> LedgerAccountPairing {
        let networkType = self.networkType
        return try await serialized {
            let appVersion = try await self.readAppVersion()
            guard appVersion.supportsPczt else {
                throw ZcashError.ledgerAppTooOld("the Zcash app is v\(appVersion), which predates PCZT signing")
            }

            let identity = try await self.readDeviceIdentity()
            let encodedUFVK = try await self.exportUFVK(zip32AccountIndex: zip32AccountIndex)
            let identityAfterExport = try await self.readDeviceIdentity()
            guard identity == identityAfterExport else {
                throw ZcashError.ledgerDeviceMismatch
            }

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
        let transport = self.transport
        return try await serialized {
            let apdu = try ZcashLedgerBackend.unifiedAddressAPDU(
                networkType: networkType,
                accountIndex: zip32AccountIndex,
                transparentAddressIndex: transparentAddressIndex,
                display: true
            )
            // The display waits on the user, so no timeout applies.
            let encoded = try await LedgerCommands.query(apdu, on: transport, timeout: nil) { reply in
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

    private func readAppVersion() async throws -> LedgerAppVersion {
        let apdu = try ZcashLedgerBackend.firmwareVersionAPDU()
        return try await LedgerCommands.query(
            apdu,
            on: transport,
            timeout: ZcashLedgerBackend.defaultTimeout,
            parse: ZcashLedgerBackend.parseAppVersion
        )
    }

    private func readDeviceIdentity() async throws -> LedgerDeviceIdentity {
        let apdu = try ZcashLedgerBackend.deviceIdentityAPDU(networkType: networkType)
        return try await LedgerCommands.query(
            apdu,
            on: transport,
            timeout: ZcashLedgerBackend.defaultTimeout,
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
