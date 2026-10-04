//
//  GiftCard.swift
//  ZcashLightClientKit
//

import CryptoKit
import Foundation

/// A Zcash gift card read from a bearer link.
///
/// A gift card is a liberated payment (ZIP 324): a small, single-purpose wallet whose key travels
/// in the link itself. The link is any `https` URL whose fragment carries the card, in the `v=1`
/// format `https://gift.zodl.com/#v=1&key=zgift1...&height=<birthday>[&amount=<ZEC>][&desc=<text>]`
/// or in the legacy JSON payment-link encoding at `/payment-links/open#v1=…`, `#v2=…` or `#v3=…`.
/// The card wallet is ZIP 32 account 0 of the card's BIP 39 seed, and its funds sit at that
/// account's Orchard-only default address (in the Ironwood pool since NU6.3).
///
/// Anyone holding the link can spend the card, including whoever issued it, who can rederive its
/// key. Treat the link like cash, and redeem it with ``GiftCardRedeemer``, which sweeps the funds
/// to the user's own wallet without leaving the recipient recoverable from the card's key.
///
/// The card's seed never leaves the SDK, and the value's `description`, `debugDescription` and
/// reflection are redacted so that printing or logging a card cannot leak it.
public struct GiftCard: Equatable, Undescribable {
    /// The encoding a gift card link was read from.
    public enum Origin: Equatable, Sendable {
        /// A `v=1` link (`https://<host>#v=1&key=…&height=…`), as `https://gift.zodl.com/` issues.
        case zodl
        /// A legacy `v1=` JSON payment link (`/payment-links/open#v1=…`).
        case legacyV1
        /// A legacy `v2=` JSON payment link (`/payment-links/open#v2=…`).
        case legacyV2
        /// A legacy `v3=` JSON payment link (`/payment-links/open#v3=…`).
        case legacyV3
    }

    /// The card wallet's 64-byte BIP 39 seed, kept out of every textual representation.
    struct Seed: Equatable, Undescribable {
        let bytes: [UInt8]
    }

    /// The encoding the link was read from.
    public let origin: Origin

    /// The network the card is on.
    public let network: NetworkType

    /// The height from which the card wallet scans for its funds; at or below the height of the
    /// transaction that funded the card.
    public let birthdayHeight: BlockHeight

    /// The amount the link says the card holds, if it states one.
    ///
    /// This is informational and unverified: anyone can edit a link. Only the balance that
    /// ``GiftCardRedeemer/check()`` finds on chain is authoritative.
    public let statedAmount: Zatoshi?

    /// The message the link carries, if any. It is text chosen by whoever made the link; display
    /// it as untrusted user content.
    public let message: String?

    /// The card wallet's Orchard-only default address, which the card is funded at.
    ///
    /// It is derived from the card's key, so it identifies the card on chain without revealing the
    /// key; it is safe to display or log.
    public let fundingAddress: UnifiedAddress

    let seed: Seed

    init(
        origin: Origin,
        network: NetworkType,
        birthdayHeight: BlockHeight,
        statedAmount: Zatoshi?,
        description: String?,
        fundingAddress: UnifiedAddress,
        seed: Seed
    ) {
        self.origin = origin
        self.network = network
        self.birthdayHeight = birthdayHeight
        self.statedAmount = statedAmount
        self.message = description
        self.fundingAddress = fundingAddress
        self.seed = seed
    }

    /// Reads a gift card link.
    ///
    /// Parsing is done by the SDK's rust layer. It is offline: no database, no network.
    /// Surrounding whitespace is ignored.
    ///
    /// - Parameter link: the link, as scanned or opened.
    /// - Throws: ``ZcashError/rustParseGiftCardLink(_:)`` when the text is not a gift card link the
    ///   SDK can read (malformed, unsupported version, or a regtest card). The error's message
    ///   names the problem and never includes any part of the link.
    public init(link: String) throws {
        self = try ZcashKeyDerivationBackend.parseGiftCardLink(link)
    }

    /// A synchronizer alias unique to this card.
    ///
    /// It is derived from a hash of the card's funding address, so it is stable for the card,
    /// distinct between cards, contains no secret, and is short enough for a file name.
    var synchronizerAlias: ZcashSynchronizerAlias {
        let digest = SHA256.hash(data: Data(fundingAddress.stringEncoded.utf8))
        let prefix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return .custom("giftcard_\(prefix)")
    }
}
