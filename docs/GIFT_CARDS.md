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

## Redeeming

```swift
let card = try GiftCard(link: scannedText)          // offline; throws ZcashError.rustParseGiftCardLink

let redeemer = try GiftCardRedeemer(
    card: card,
    network: ZcashNetworkBuilder.network(for: .mainnet),
    endpoint: endpoint                               // the app's lightwalletd endpoint
)

let status = try await redeemer.check()             // syncs the card wallet from its birthday
switch status.state {
case .ready:   break                                // status.spendable can be swept now
case .pending: break                                // waiting for 10 confirmations; check() again later
case .empty:   break                                // already redeemed, or never funded
}

mainSynchronizer.stop()                             // optional: lets the claim have the database
let redemption = try await redeemer.redeem(
    to: myUnifiedAddress,
    memo: try Memo(string: "Gift card"),
    recordIn: mainSynchronizer                       // the wallet myUnifiedAddress belongs to
)
// redemption.results: one TransactionSubmitResult per created transaction (usually one)
// redemption.recordedInDestination: the main wallet knows the claim and trusts it (ZIP 315)
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

## Trust of the claim transaction (ZIP 315)

To the user's main wallet, the claim is a payment from another wallet. Left to chain scanning, it
would appear only once a sync finds it, and [ZIP 315](https://zips.z.cash/zip-0315) would hold its
outputs for 10 confirmations before they can be spent, as for any external receive. But this device
authored the claim — it chose the recipient and built the transaction — so ZIP 315's allowance for
wallets to "enable specific external transactions as trusted" applies, and the SDK uses it:

- Pass the main wallet's synchronizer as `recordIn:`. Once a server has accepted the claim,
  `GiftCardRedeemer` reads the raw transaction back from the card wallet and calls
  `Synchronizer.recordTrustedTransaction(_:txId:)` on the destination, which stores it (the receive
  shows at once, unmined, with its memo) and marks it trusted. The main wallet can then spend the
  gift after 3 confirmations instead of 10. The next sync mines the stored transaction as usual.
- The call goes straight to the wallet database, so it works while the main synchronizer is
  stopped — which is how an app typically runs a claim, so the two wallets do not compete for the
  shared database executor. Restart the main synchronizer afterwards.
- Recording can never fail the redemption: the funds are already on their way. A failure is logged
  and reported as `Redemption.recordedInDestination == false`; the main wallet then learns about the
  claim from the chain, as an ordinary (untrusted, 10-confirmation) receive. Nothing is lost.
- Only accepted submissions (`.success`) are recorded. A transaction rejected by every server is
  not stored in the destination.
- Trust is per transaction and reversible: `Synchronizer.setTransactionTrust(txId:trusted:)` marks
  any transaction the wallet already knows as trusted or untrusted; the status of an unknown
  transaction is not recorded, so store it first (`recordTrustedTransaction` does both).
- Trust shortens the wait; it does not weaken safety against reorgs beyond what ZIP 315 accepts
  for the wallet's own transactions, and it never makes an unmined output spendable.

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
- `cleanup()` never loses funds: the key is in the link. If a submission failed, clean up and use
  a new redeemer to retry, because the old one treats the notes as spent until its transaction
  expires.
- Tor and exchange-rate fetching are off for the card wallet, and logging is off by default so the
  transaction that links the card to the user's address does not end up in shared logs.

## Errors

| Error | Meaning |
|---|---|
| `rustParseGiftCardLink` (`ZRUST0156`) | Not a readable gift card link. The message never contains the link. |
| `giftCardNetworkMismatch` (`ZGIFT0001`) | The card, or the redeem address, is for another network. |
| `giftCardRedeemerAlreadyActive` (`ZGIFT0002`) | Another redeemer for this card is alive. |
| `giftCardRedeemerNotReady` (`ZGIFT0003`) | `redeem(to:)` before `check()`. |
| `giftCardNothingToRedeem` (`ZGIFT0004`) | Nothing spendable: empty, or still pending. |
| `giftCardRedeemerCleanedUp` (`ZGIFT0005`) | The redeemer was cleaned up. |

`check()` also rethrows the card wallet's sync error, and `redeem(to:)` the errors of
`proposeSendMax` and `createProposedTransactions`. The destination's errors are never thrown; see
`Redemption.recordedInDestination`.
