# Gift cards

A gift card is a liberated payment (ZIP 324): a bearer link that carries the key of a small,
single-purpose wallet. The link is any `https` URL whose fragment carries the card, in the `v=1`
format or in the legacy JSON payment-link encoding at `/payment-links/open#vN=`:

```
https://gift.zodl.com/#v=1&key=zgift1…&height=<birthday>[&amount=<ZEC>][&desc=<text>]
https://<host>/payment-links/open#v3=…   (legacy; also v1= and v2=)
```

The key is BIP 39 entropy (empty passphrase); the card wallet is ZIP 32 account 0 of its seed, and
the funds sit at that account's Orchard-only default address (in the Ironwood pool since NU6.3).
The host is not part of the card and the link fragment never reaches a server. Anyone holding the
link can spend the card, including its issuer, who can rederive the key. `GiftCard.origin` reports
the encoding a link was read from (`.zodl` for `v=1`, `.legacyV1`/`.legacyV2`/`.legacyV3`).

Parsing is done by the SDK's rust layer, from the module the card tooling shares, so every client
reads a link the same way:

- The birthday must be at or above the network's NU5 activation height. Cards hold Orchard funds
  only, which cannot exist before NU5, and a lower height would only make the card wallet scan
  millions of blocks for nothing. Such a link throws `giftCardLinkInvalidBirthday`.
- `message` is sanitized: line breaks and other control whitespace become a space, and control and
  invisible formatting characters (bidi overrides and isolates, zero-width spaces and the like)
  are removed. A message that is blank afterwards is `nil`. It is still text anyone could have
  written; show it as untrusted content.
- A malformed `amount` or `desc` is read as absent rather than refusing a funded card; `v`, `key`
  and `height` are strict.

## Redeeming

```swift
// At launch: delete card wallets a crash or a killed app left behind.
try? GiftCardRedeemer.removeLeftoverWallets()

let card = try GiftCard(link: scannedText)          // offline; see "Errors" below

let redeemer = try GiftCardRedeemer(
    card: card,
    network: ZcashNetworkBuilder.network(for: .mainnet),
    endpoint: endpoint,                              // the app's lightwalletd endpoint
    isTorEnabled: mainWalletUsesTor                  // the main wallet's Tor setting
)

let status = try await redeemer.check()             // syncs the card wallet from its birthday
switch status.state {
case .ready:   break                                // status.spendable can be swept now
case .pending: break                                // waiting for 10 confirmations; check() again later
case .dust:    break                                // the fee would take everything; nothing to redeem
case .empty:   break                                // already redeemed, or never funded
}

await mainSynchronizer.stopAndWait()                // optional: await the main wallet's stop operation
let redemption = try await redeemer.redeem(
    to: myUnifiedAddress,
    memo: try Memo(string: "Gift card"),
    recordIn: mainSynchronizer                       // the wallet myUnifiedAddress belongs to
)
// redemption.results: one TransactionSubmitResult per created transaction (usually one)
// redemption.recordedInDestination: the untrusted claim is visible in main-wallet history
// Recording alone does not confirm the claim or make its funds spendable (ZIP 315).
try await mainSynchronizer.start()

try await redeemer.cleanup()                        // stops and deletes the temporary wallet
```

- `statedAmount` and `message` come from the link and are unverified. Show `GiftCardStatus`
  amounts as the card's value, and the message as untrusted user content.
- `redeem(to:memo:recordIn:)` sends the whole spendable balance, with the optional `memo`, minus
  the ZIP 317 fee (normally 10,000 zatoshis, which a card is funded with on top of its face value).
  It discards the outgoing viewing key, so the card's key cannot reveal the recipient; the
  redeeming wallet still records the incoming payment as usual. `redeem(to:memo:)` does the same
  without a destination and returns the results alone.
- With an address that has an Orchard receiver, no Sapling parameters are downloaded.

## Confirmations (ZIP 315)

[ZIP 315](https://zips.z.cash/zip-0315) distinguishes trusted notes (the wallet's own change, or
outputs of transactions the wallet chose to trust) from untrusted ones (anything received from
another wallet). Both wallets in a redemption use the SDK's transfer policy: **3 confirmations
for trusted notes, 10 for untrusted ones.** The SDK's tests pin both numbers.

**The card side: 10.** Every note on a card was sent by another wallet — the issuer's — so it is
untrusted, and `check()` reports `.pending` until it has 10 confirmations. This is the guard that
matters: the issuer can rederive the card's key, and could in principle try to undo the funding
with a reorg. Ten confirmations is ZIP 315's bar for funds that someone else controlled.

**The claim side: 10.** The destination records the claim as an untrusted external receive and
uses the default ten-confirmation wait. Even after the card's funding has ten confirmations,
the issuer and anyone holding the link still share its spending key and could construct a
competing spend of the same inputs. Building and signing the claim on this device therefore does
not establish exclusive control over those inputs. This is the shared-key risk that motivates
the ordinary untrusted policy; it is not a claim that an attack has been reproduced.

## Immediate claim recording

- Pass the main wallet's synchronizer as `recordIn:`. Once a server has accepted the claim,
  `GiftCardRedeemer` reads the raw transaction back from the card wallet and stores it in the
  destination (the receive shows at once, unmined, with its memo), explicitly marked as untrusted.
  The main wallet follows its normal external-receive policy: ten confirmations by default before
  the gift becomes spendable. The next sync mines the stored transaction as usual.
- Only the SDK's own synchronizers (`SDKSynchronizer`, `SlipstreamSynchronizer`) can record the
  claim. Recording is internal to the SDK. With any other conformer, `recordedInDestination` is
  `false` and the claim arrives through sync.
- The call goes straight to the wallet database, so it works while the main synchronizer is
  stopped — which is how an app typically runs a claim, so the two wallets do not compete for the
  shared database executor. The example uses a main synchronizer typed as
  `AwaitableStopSynchronizer`, the optional capability both SDK implementations support. Await
  `stopAndWait()` before starting work that needs the stop operation to finish; synchronous
  `stop()` only requests it. Completion includes classic processor actions and Tor dormancy, or
  Slipstream's queued teardown and earlier lifecycle work. It completes even when no new stopped
  state is emitted, including idle or unprepared paths. This is not full engine quiescence: classic
  cancelled background tasks are not joined, and Slipstream's engine can return a non-quiescent
  stop. Keep ownership of the pause so other app lifecycle paths do not start the main wallet
  while the claim is running, then restart it afterwards.
- Recording can never fail the redemption: the funds are already on their way. A failure is logged
  and reported as `Redemption.recordedInDestination == false`; the main wallet then learns about the
  claim from the chain, as an ordinary untrusted receive. Nothing is lost.
- Only accepted submissions (`.success`) are recorded. A transaction rejected by every server is
  not stored in the destination.
- Recording a claim explicitly clears any prior trusted status for that transaction, including
  when repeated. It does not migrate other stored trust records or change the SDK's general
  support for marking transactions as trusted or untrusted.
- Immediate history visibility does not make an unmined output spendable.

## Lifecycle and concurrency

- The temporary wallet is an `SDKSynchronizer` with a custom alias derived from a hash of the card's
  funding address (`GiftCardRedeemer.alias`), never `.default`. All of its files live in one
  directory under `storageDirectory` (the temporary directory by default), which `cleanup()`
  deletes, including the files `wipe()` leaves behind.
- It runs alongside the app's main synchronizer. Both share the SDK's global database executor, so
  each wallet's database work waits for the other's; expect the main wallet to sync more slowly
  while a card is being checked.
- Only one redeemer per card can be alive in the process; a second throws
  `giftCardRedeemerAlreadyActive` until the first is cleaned up or released.
- Calls on a redeemer run one at a time, in order. Cancelling the task awaiting `check()` stops
  the wait (throws `CancellationError`); the card wallet keeps syncing until `cleanup()`.
- A cancelled queued `check()` or `redeem(to:memo:recordIn:)` throws `CancellationError`
  when its turn arrives. Cancellation is checked again after redemption preparation and on the
  database executor immediately before native claim creation. Cancellation observed at these
  checkpoints prevents storing or submitting a claim. Once synchronous native creation starts,
  it cannot be cancelled or rolled back; cancellation does not establish whether the claim was
  created or submitted, so recheck the card before retrying.
- `cleanup()` runs to completion even when the calling task is cancelled, including when it was
  queued behind another operation.
- `cleanup()` never loses funds: the key is in the link. If a submission failed, clean up and use
  a new redeemer to retry, because the old one treats the notes as spent until its transaction
  expires.
- A card wallet holds the card's keys, its notes and the claim with its recipient. A redeemer
  released without `cleanup()`, a crash or a killed app leaves it on disk (excluded from backups).
  Call `GiftCardRedeemer.removeLeftoverWallets(in:)` at launch, with the same `storageDirectory`;
  it never touches a redeemer alive in the process.
- Tor follows `isTorEnabled`: the birthday lookup, the sync and the claim's submission all go over
  Tor when it is `true`. Pass the main wallet's setting; with `false` the server sees the device's
  IP address together with the card's birthday, its sync and the claim.
- The birthday lookup asks the server for the tree state of the block before the card's birthday
  and uses it only if the state is for exactly that height; otherwise the card wallet starts from
  the nearest bundled checkpoint below, which is slower but never wrong.
- Exchange-rate fetching is off for the card wallet, and logging is off by default so the
  transaction that links the card to the user's address does not end up in shared logs.

## Errors

The parse errors come from a stable code the rust layer reports, not from its message text, and
none of them carries any part of the link.

| Error | Meaning |
|---|---|
| `giftCardLinkNotAGiftCard` (`ZGIFT0006`) | Not an `https` URL carrying a gift card. |
| `giftCardLinkUnsupportedVersion` (`ZGIFT0007`) | A gift card link of a version this SDK does not read. |
| `giftCardLinkUnsupportedNetwork` (`ZGIFT0008`) | A card for regtest or an unknown network. |
| `giftCardLinkInvalidBirthday` (`ZGIFT0009`) | Malformed birthday, or below NU5 activation. |
| `giftCardLinkInvalid` (`ZGIFT0010`) | Any other malformed link. |
| `giftCardNetworkMismatch` (`ZGIFT0001`) | The card, or the redeem address, is for another network. |
| `giftCardRedeemerAlreadyActive` (`ZGIFT0002`) | Another redeemer for this card is alive. |
| `giftCardRedeemerNotReady` (`ZGIFT0003`) | `redeem(to:)` before `check()`. |
| `giftCardNothingToRedeem` (`ZGIFT0004`) | Nothing spendable: empty, still pending, or dust (the fee would take everything). |
| `giftCardRedeemerCleanedUp` (`ZGIFT0005`) | The redeemer was cleaned up. |

`check()` also rethrows the card wallet's sync error, and `redeem(to:)` the errors of
`proposeSendMax` and `createProposedTransactions`. The destination's errors are never thrown; see
`Redemption.recordedInDestination`.
