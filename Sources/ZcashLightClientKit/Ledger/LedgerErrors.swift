//
//  LedgerErrors.swift
//  ZcashLightClientKit
//

import Foundation

extension LedgerFFIError {
    /// The public error for this failure.
    ///
    /// A `0x6901` refusal only reaches here once its resend budget is spent, and is then reported as a
    /// transient device refusal.
    var zcashError: ZcashError {
        switch kind {
        case .userRejected:
            return .ledgerUserRejected
        case .wrongApp:
            return .ledgerWrongApp(statusWord ?? 0)
        case .appTooOld:
            return .ledgerAppTooOld(reason)
        case .deviceMismatch:
            return .ledgerDeviceMismatch
        case .capsMismatch:
            return .ledgerCapsMismatch(reason)
        case .derivationBudgetExhausted:
            return .ledgerDerivationBudgetExhausted
        case .deviceRefused:
            return .ledgerDeviceRefused(statusWord ?? 0, isTransient)
        case .cmdNotAccepted:
            return .ledgerDeviceRefused(statusWord ?? 0x6901, true)
        case .transactionNotSignable:
            return .ledgerTransactionNotSignable(reason)
        case .malformedReply:
            return .ledgerMalformedReply(reason)
        case .invalidInput:
            return .ledgerInvalidInput(reason)
        case .internal:
            return .ledgerInternal(reason)
        }
    }
}

/// Converts a failure inside the Ledger integration into the error the public API throws: a
/// ``ZcashError`` for every Ledger failure, and a `CancellationError` passed through unchanged.
func ledgerZcashError(_ error: Error) -> Error {
    switch error {
    case let ffiError as LedgerFFIError:
        return ffiError.zcashError
    case is ZcashError, is CancellationError:
        return error
    default:
        return ZcashError.ledgerTransportFailed(error)
    }
}

extension ZcashError {
    /// Whether a fresh attempt at the same Ledger operation could succeed, or `nil` for an error that
    /// did not come from the Ledger integration.
    ///
    /// `true` after the user declined on the device (they may approve on a second attempt) and after a
    /// device refusal whose condition can clear, such as a locked device. `false` for every failure
    /// that is a function of the transaction or the device, where a retry fails the same way. A
    /// transport failure is `true`: the connection is closed, and a new one may succeed. It never means
    /// "resend the last command": a fresh attempt starts over.
    public var ledgerIsRestartable: Bool? {
        switch self {
        case .ledgerUserRejected, .ledgerAppOpenRejected:
            return true
        case let .ledgerDeviceRefused(_, isTransient):
            return isTransient
        case .ledgerBluetoothDisconnected, .ledgerTimeout, .ledgerTransportClosed, .ledgerTransportFailed,
            .ledgerBluetoothConnectionFailed, .ledgerDeviceNotFound, .ledgerBluetoothPoweredOff:
            return true
        case .ledgerWrongApp, .ledgerAppTooOld, .ledgerDeviceMismatch, .ledgerCapsMismatch,
            .ledgerDerivationBudgetExhausted, .ledgerTransactionNotSignable, .ledgerMalformedReply,
            .ledgerInvalidInput, .ledgerInternal, .ledgerBluetoothUnsupported, .ledgerBluetoothUnauthorized,
            .ledgerBluetoothPairingRefused, .ledgerAppNotInstalled:
            return false
        default:
            return nil
        }
    }
}
