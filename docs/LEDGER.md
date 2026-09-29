# Ledger hardware wallets over Bluetooth

The SDK pairs accounts on, and signs transactions with, a Ledger device running the Zcash app,
over Bluetooth LE. The device holds the spending keys: the wallet imports the account's unified
full viewing key, builds transactions as PCZTs, and has the device sign them.

Supported devices are the Bluetooth models (Nano X, Stax, Flex and Nano Gen5) running Zcash app
3.6.0 or newer. A transaction with Ironwood outputs needs app 3.9.0 or newer; 3.9.3 is recommended.

The engine behind this is `pczt_ledger` (zodl-inc/pczt-ledger). It performs no I/O: the SDK moves the
bytes, and every protocol rule, pre-flight check and parser lives in the engine.

## App requirements

- iOS: add `NSBluetoothAlwaysUsageDescription` to the app's `Info.plist`. The first scan shows the
  system's Bluetooth permission prompt.
- macOS: a sandboxed app needs the `com.apple.security.device.bluetooth` entitlement.
- The first connection to a device brings up Bluetooth pairing: the system shows a pairing request and
  the device shows a code for the user to confirm. A device that was reset, or unpaired on the phone,
  fails with `ZcashError.ledgerBluetoothPairingRefused`; the user removes it from the system Bluetooth
  settings and pairs again.

## Connecting

```swift
let scanner = LedgerBluetoothScanner(logger: logger)

for try await devices in scanner.devices() {
    // Show `devices` (model, name, signal strength) and let the user pick one; leaving the loop
    // stops the scan.
}

let transport = try await scanner.connect(to: pickedDevice)
```

`LedgerBluetoothTransport` conforms to `LedgerAPDUTransport`, the only thing the pairing and signing
code needs; a test double conforms to it too.

A transport closes itself when an exchange fails after its command reached the wire (a timeout, a
disconnect, a malformed reply) or when the task awaiting it is cancelled: the device's reply to that
command could otherwise be read as the reply to the next one. Every later call then throws
`ZcashError.ledgerTransportClosed`, and the recovery is a new connection. A refusal from the device
(the user declining, a locked device, another app open) leaves the transport open.

After a first pairing the device is on its dashboard rather than the Zcash app, and any command then
fails with `ledgerWrongApp`. Before creating a `LedgerDevice` or signing, call
`LedgerZcashApp.ensureZcashAppOpen(transport:reconnect:)` on a fresh connection and use the transport
it returns instead of the one passed in: the Bluetooth link can drop while the device switches apps,
and `ensureZcashAppOpen` reconnects through `reconnect` when it does. Each such reconnect gets
10 seconds of its own and is cancelled past them; a reconnect that fails starts the wait for the app
over, since the device may still be rebooting into it, and the third one that fails propagates its
own failure (typically `ledgerBluetoothConnectionFailed`) instead of the generic `ledgerWrongApp`
timeout.

## Pairing an account

```swift
let device = LedgerDevice(transport: transport, networkType: .mainnet)
let pairing = try await device.pairAccount(zip32AccountIndex: Zip32AccountIndex(0))

let accountUUID = try await synchronizer.importAccount(
    ufvk: pairing.ufvk.stringEncoded,
    seedFingerprint: nil,
    zip32AccountIndex: nil,
    purpose: .spending,
    name: "Ledger",
    keySource: Account.ledgerKeySource,
    birthday: birthday
)
// Persist `pairing.binding` (Codable) next to `accountUUID`.
```

`pairAccount` reads the app version (and refuses an app that cannot sign), reads the device's
identity, and asks the user to approve the viewing key export on the device. The identity is
read once, before the export: the Zcash app leaves a status screen up after the export and drops
the next command until the user dismisses it, and a transport speaks to exactly one peripheral,
so the device that answered the probe is the device that exported the key.

Pass `nil` for the seed fingerprint and the ZIP 32 account index: a Ledger never reveals its seed
fingerprint, and the binding carries the account index the signing session needs.
`Account.ledgerKeySource` (`"ledger"`) lets the wallet recognize its Ledger accounts; the SDK reads
nothing from it.

### The device identity

`LedgerDeviceIdentity` (`tpk0-` and 64 hex digits) is a hash of the public key at
`m/44'/coin'/0'/0/0`. It names the seed rather than the hardware: two devices restored from the same
seed share it. It is per network. It is not a secret, but it is linkable to the device's first
transparent address once that address has spent on chain, so store it with the account and never
log it; its `description` prints a placeholder, and `stringEncoded` returns the value for storage.

## Verifying a receiving address on the device

```swift
let displayed = try await device.displayUnifiedAddress(
    zip32AccountIndex: Zip32AccountIndex(0),
    transparentAddressIndex: 0
)
```

The device shows the address and waits for the user. The address it shows and returns holds only the
account's Orchard receiver at diversifier index 0, whatever `transparentAddressIndex` is: the index
selects the transparent address the device shows alongside it. Compare the result with a unified
address holding that single Orchard receiver. The account's default unified address carries a
transparent receiver too, and never matches.

## Sending

```
proposal ─ createPCZTFromProposal ─ pczt
  ├─ addProofsToPCZT(pczt)                                      → pcztWithProofs
  └─ signPCZTWithLedger(pczt, accountUUID, binding, transport)   → pcztWithSigs
createTransactionFromPCZT(pcztWithProofs, pcztWithSigs)          → submit
```

```swift
let pczt = try await synchronizer.createPCZTFromProposal(accountUUID: accountUUID, proposal: proposal)

async let pcztWithProofs = synchronizer.addProofsToPCZT(pczt: pczt)
let pcztWithSigs = try await synchronizer.signPCZTWithLedger(
    pczt: pczt,
    accountUUID: accountUUID,
    binding: binding,
    transport: transport,
    progress: { progress in /* update the UI */ }
)

let submission = try await synchronizer.createTransactionFromPCZT(
    pcztWithProofs: try await pcztWithProofs,
    pcztWithSigs: pcztWithSigs
)
```

Pass the PCZT `createPCZTFromProposal` returned to both calls, unredacted. The signing call prepares
its own copy for the device: it redacts it to the signer view, adds the key paths the device signs
at, and marks a transparent change output as change. The signed PCZT therefore differs from the
input by more than signatures, and the combine step in `createTransactionFromPCZT` merges it with the
proven PCZT: every field the Ledger path adds is one the prover's copy leaves empty.

The ceremony, reported through `LedgerSigningProgress`:

1. `identifyingDevice`: the app version is read, and the transaction is checked against every rule
   and limit of that version. A transaction the device cannot sign fails here with
   `ZcashError.ledgerTransactionNotSignable`, or `ledgerAppTooOld`, before anything is sent. The
   device's identity is then checked against the binding (`ledgerDeviceMismatch` otherwise).
2. `streaming(sent:total:)`: the transaction is sent to the device.
3. `awaitingReviewOnDevice`: the device shows the transaction. No timeout applies until the user
   approves or rejects it; a rejection fails with `ledgerUserRejected`.
4. `signing`, then `complete`.

The device's signatures are verified before the signed PCZT is returned.

### Change outputs

The Ledger Zcash app signs exactly one change output per transaction; a PCZT with two or more fails
the `identifyingDevice` check above with `ZcashError.ledgerTransactionNotSignable` before anything is
sent. The proposal itself already avoids this: `proposeTransfer`, `proposefulfillingPaymentURI` and
`proposeShielding` build at most one change output for an account whose `keySource` is
`Account.ledgerKeySource` (compared case-insensitively). Every other account keeps splitting change
into up to four outputs of at least 0.1 ZEC each, unchanged.

## Errors

Every Ledger failure is a `ZcashError` from the `ledger` family (`ZLEDG0001`–`ZLEDG0023`), or
`CancellationError`. `ZcashError.ledgerIsRestartable` says whether a fresh attempt could succeed:
after the user declined, after the device is not running the Zcash app or has exhausted its
derivation budget (opening or reopening it lets a fresh attempt succeed), after a device condition
that clears (a locked device), and after a transport failure on a new connection. It never means
"resend the last command".

| Error | Meaning and remedy |
|---|---|
| `ledgerWrongApp` | The dashboard, or another app, is open (also when the device reports either directly rather than as a plain refusal), or the device did not switch in time: call `LedgerZcashApp.ensureZcashAppOpen`. Restartable. |
| `ledgerAppNotInstalled` | The Zcash app is not installed: the user installs it on the device with Ledger Live. |
| `ledgerAppOpenRejected` | The user declined opening the Zcash app on the device; restartable. |
| `ledgerAppTooOld` | Update the Zcash app. |
| `ledgerDerivationBudgetExhausted` | The Zcash app ran out of key derivations for this run: close and reopen it on the device. Restartable. |
| `ledgerDeviceMismatch` | Connect the paired device. |
| `ledgerCapsMismatch` | The app version changed during the ceremony: try again. |
| `ledgerDeviceRefused(statusWord, isTransient)` | Any other refusal; `isTransient` for a condition that clears, such as a locked device. |
| `ledgerTransactionNotSignable` | A device rule or limit refuses the transaction; nothing was sent. |
| `ledgerMalformedReply` | The reply was not what the protocol promises, or a signature did not verify. |
| Bluetooth errors | `ledgerBluetoothUnsupported`, `ledgerBluetoothUnauthorized`, `ledgerBluetoothPoweredOff`, `ledgerDeviceNotFound`, `ledgerBluetoothConnectionFailed`, `ledgerBluetoothDisconnected`, `ledgerBluetoothPairingRefused`, `ledgerTimeout`, `ledgerTransportClosed`. |

Error reasons carry no command or reply bytes, PCZT, viewing key, address, device identity or
signature, and the SDK logs only lengths, stages and error codes. The `ledgerTransportFailed` case
wraps whatever a custom transport threw.
