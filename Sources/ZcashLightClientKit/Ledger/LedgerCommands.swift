//
//  LedgerCommands.swift
//  ZcashLightClientKit
//

import Foundation

/// The exchange rules the pairing commands and the signing ceremony share.
enum LedgerCommands {
    /// Exchanges one command, closing the transport when the exchange fails.
    ///
    /// A failed exchange may have put its command on the wire and left the reply uncollected, so the
    /// transport cannot be trusted with another command: it is closed, whatever the failure, before
    /// the error is rethrown. A cancelled task counts as a failed exchange.
    static func exchange(_ apdu: Data, on transport: LedgerAPDUTransport, timeout: TimeInterval?) async throws -> Data {
        do {
            try Task.checkCancellation()
            return try await transport.exchange(apdu, timeout: timeout)
        } catch {
            await transport.close()
            throw ledgerZcashError(error)
        }
    }

    /// Sends a one-shot command and parses its reply, resending it while the device SDK refuses the
    /// frame with `0x6901`.
    ///
    /// `0x6901` means the frame never reached the Zcash app, so a resend is not a repeat. The command
    /// is sent at most `maxCmdNotAcceptedRetries + 1` times, with the engine's backoff before each
    /// resend. Stateful exchanges do not belong here: the viewing key export and the signing session
    /// absorb their own refusals.
    static func query<T>(
        _ apdu: Data,
        on transport: LedgerAPDUTransport,
        timeout: TimeInterval?,
        parse: (Data) throws -> T
    ) async throws -> T {
        var retries = 0
        while true {
            let reply = try await exchange(apdu, on: transport, timeout: timeout)
            do {
                return try parse(reply)
            } catch let error as LedgerFFIError where error.kind == .cmdNotAccepted && retries < ZcashLedgerBackend.maxCmdNotAcceptedRetries {
                retries += 1
                try await backOff(transport: transport)
            }
        }
    }

    /// Waits out a `0x6901` refusal before the identical command is resent. A cancelled wait closes the
    /// transport like a cancelled exchange.
    static func backOff(transport: LedgerAPDUTransport) async throws {
        do {
            try await Task.sleep(nanoseconds: ZcashLedgerBackend.cmdNotAcceptedBackoffNanoseconds)
        } catch {
            await transport.close()
            throw error
        }
    }
}

/// Admits async operations one at a time, in arrival order.
///
/// An actor alone does not serialize them: it is reentrant at every suspension point, so two exchanges
/// awaiting a device reply would interleave their commands. A caller brackets its operation with
/// ``acquire()`` and ``release()``, releasing on every path.
actor LedgerSerialGate {
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Waits until no other operation holds the gate, then holds it.
    func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Hands the gate to the next waiter, or frees it.
    func release() {
        guard !waiters.isEmpty else {
            isBusy = false
            return
        }

        waiters.removeFirst().resume()
    }
}
