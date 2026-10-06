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
/// ``acquire()`` and ``release()``, releasing on every path it takes once ``acquire()`` returns. A
/// cancelled caller never comes out of ``acquire()`` holding the gate: either it throws before ever
/// queuing, or it throws after being handed the gate and passes it straight on, so it must call
/// ``release()`` only when ``acquire()`` itself returned normally.
actor LedgerSerialGate {
    private var isBusy = false
    private var waiters: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextWaiterID = 0

    /// How many callers are queued behind the one currently holding the gate. Test-only visibility
    /// into otherwise-private state, so a test can wait for a caller to actually be queued instead
    /// of guessing with a sleep.
    var queuedCount: Int { waiters.count }

    /// Waits until no other operation holds the gate, then holds it.
    ///
    /// Throws `CancellationError` instead of holding the gate when the calling task is already
    /// cancelled, or becomes cancelled while queued. Admission otherwise stays in arrival order.
    func acquire() async throws {
        try Task.checkCancellation()

        guard isBusy else {
            isBusy = true
            return
        }

        let id = nextWaiterID
        nextWaiterID += 1

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append((id, continuation))
            }

            // The continuation above resumed normally, so `release()` reached this waiter and
            // handed it the gate -- but `cancelWaiter(id)` runs in a separate `Task` hop off
            // `onCancel` below, which may not have run yet. A caller cancelled in that narrow
            // window must not come out of this call holding the gate: pass it on to whoever is
            // next, instead of returning normally to a cancelled task whose own operation would
            // fail later and close the transport out from under the caller it was just handed to.
            if Task.isCancelled {
                release()
                throw CancellationError()
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Hands the gate to the next waiter, or frees it.
    func release() {
        guard !waiters.isEmpty else {
            isBusy = false
            return
        }

        waiters.removeFirst().continuation.resume()
    }

    /// Removes a cancelled waiter and resumes it with `CancellationError`, unless it has already been
    /// admitted by ``release()``: whichever of the two reaches it first wins, and the other finds it
    /// already gone.
    private func cancelWaiter(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }

        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
