//
//  LedgerModels.swift
//  ZcashLightClientKit
//

import Foundation

/// The stable name of one Ledger device on one network: `tpk0-` followed by 64 lowercase hex digits.
///
/// It is a hash of the public key the device derives at `m/44'/coin'/0'/0/0`, so two devices restored
/// from the same seed share it and devices with different seeds do not. The signing ceremony reads it
/// back from the connected device before it sends anything of a transaction, and refuses a device
/// that answers with another identity.
///
/// The value is not a secret, but it is linkable: once the first transparent address of the device's
/// first account has spent on chain, anyone can match the identity to that address. Store it next to
/// the paired account and never log it. `description` and reflection print a placeholder; the value
/// itself is available through ``stringEncoded`` for persistence.
public struct LedgerDeviceIdentity: Equatable, Hashable, Sendable, StringEncoded, Undescribable {
    let encoding: String

    public var stringEncoded: String { encoding }

    /// Validates a stored device identity.
    ///
    /// - Parameter encoding: The value ``stringEncoded`` returned when the identity was stored.
    /// - Throws: ``ZcashError/ledgerInvalidInput(_:)`` when the value is not a well-formed identity. The
    ///   error never repeats the value.
    public init(encoding: String) throws {
        do {
            try ZcashLedgerBackend.validateDeviceIdentity(encoding)
        } catch {
            throw ledgerZcashError(error)
        }
        self.encoding = encoding
    }

    /// Wraps an identity the Rust layer produced or validated.
    init(validatedEncoding: String) {
        self.encoding = validatedEncoding
    }
}

extension LedgerDeviceIdentity: Codable {
    /// Decodes the identity from its string encoding, validating it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(encoding: try container.decode(String.self))
    }

    /// Encodes the identity as its string encoding.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(encoding)
    }
}

/// The version of the Zcash app running on a Ledger device.
public struct LedgerAppVersion: Equatable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let major: UInt8
    public let minor: UInt8
    public let patch: UInt8

    /// Whether this version can sign transactions for this SDK.
    ///
    /// Zcash app 3.6.0 introduced the PCZT instructions; a transaction with Ironwood outputs further
    /// needs 3.9.0. The signing session applies both rules.
    public let supportsPczt: Bool

    public var description: String {
        "\(major).\(minor).\(patch)"
    }
}
