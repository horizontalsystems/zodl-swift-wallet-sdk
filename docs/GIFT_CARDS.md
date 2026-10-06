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

## Confirmations (ZIP 315)

[ZIP 315](https://zips.z.cash/zip-0315) distinguishes trusted notes (the wallet's own change, or
outputs of transactions the wallet chose to trust) from untrusted ones (anything received from
another wallet). Both wallets in a redemption use the SDK's transfer policy: **3 confirmations
for trusted notes, 10 for untrusted ones.** The SDK's tests pin both numbers.

**The card side: 10.** Every note on a card was sent by another wallet — the issuer's — so it is
untrusted, and `check()` reports `.pending` until it has 10 confirmations. This is the guard that
matters: the issuer can rederive the card's key, and could in principle try to undo the funding
with a reorg. Ten confirmations is ZIP 315's bar for funds that someone else controlled.

**The claim side: 3.** The claim spends only notes that already had 10 confirmations, and this
device chose its recipient, built it and signed it. To the main wallet it looks like an external
receive, which would wait 10 confirmations more, but ZIP 315 lets a wallet "enable specific external
transactions as trusted", and the claim is the case it describes: the risk the 10-confirmation
rule guards against (someone else's transaction being replaced) does not apply to a transaction
whose inputs were final and whose construction this device controlled. So the SDK records it as
trusted, and the main wallet can spend the gift after 3 confirmations — the same wait as its own
change.

## Trust of the claim transaction

- Pass the main wallet's synchronizer as `recordIn:`. Once a server has accepted the claim,
  `GiftCardRedeemer` reads the raw transaction back from the card wallet and stores it in the
  destination (the receive shows at once, unmined, with its memo), marked as trusted. The main
  wallet can then spend the gift after 3 confirmations instead of 10. The next sync mines the
  stored transaction as usual.
- Only the SDK's own synchronizers (`SDKSynchronizer`, `SlipstreamSynchronizer`) can record the
  claim. The trust calls are internal to the SDK: which transaction to trust is decided by the
  redeemer, never by a caller with an arbitrary transaction or id. With any other conformer,
  `recordedInDestination` is `false` and the claim arrives through sync.
- The call goes straight to the wallet database, so it works while the main synchronizer is
  stopped — which is how an app typically runs a claim, so the two wallets do not compete for the
  shared database executor. Restart the main synchronizer afterwards.
- Recording can never fail the redemption: the funds are already on their way. A failure is logged
  and reported as `Redemption.recordedInDestination == false`; the main wallet then learns about the
  claim from the chain, as an ordinary (untrusted, 10-confirmation) receive. Nothing is lost.
- `recordedInDestination` is `true` only when the claim is actually stored in the destination and
  marked as trusted. A claim that does not involve the destination's wallet (`recordIn:` is not the
  wallet `recipient` belongs to) is not stored there, so nothing is trusted and the flag is `false`.
- Only accepted submissions (`.success`) are recorded. A transaction rejected by every server is
  not stored in the destination.
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
