//! Gift cards: bearer links that carry the key of a small, single-purpose wallet.
//!
//! This module is shared verbatim between the wallet SDK backends and the command-line
//! tooling that mints cards. Keep every copy byte-identical and update the shared test
//! vectors (`gift_vectors.json`) whenever behavior changes.
//!
//! A card is a 32-byte secret. The secret is the entropy of a 24-word English BIP 39
//! phrase; the card wallet is ZIP 32 account 0 of that phrase's seed (empty passphrase),
//! and funds are sent to its Orchard-only default address. Any wallet that can restore a
//! phrase can therefore recover a card.
//!
//! Card secrets minted by a wallet are derived from that wallet's seed with ZIP 32
//! registered key derivation under ZIP 324, so a sender can always rederive (and reclaim)
//! cards that were never redeemed:
//!
//! ```text
//! secret_i = registered::SecretKey::from_subpath("ZODL gift cards", seed, 324,
//!                                                [coin_type', i']).data()
//! ```
//!
//! A card is shared as a link whose fragment carries the secret, so it is never sent to a
//! server:
//!
//! ```text
//! https://gift.zodl.com/#v=1&key=<bech32m secret>&height=<birthday>[&amount=<ZEC>][&desc=<text>]
//! ```
//!
//! The Bech32m human-readable part of `key` selects the network. `height` is a block
//! height at or below the height of the transaction that funded the card, from which a
//! wallet scans for its funds. `amount` and `desc` are informational; the funds found on
//! chain are authoritative.
//!
//! This module also reads the gift card links issued by the Vizor wallet (`v1`, `v2` and
//! `v3` payloads at `https://link.vizor.cash/payment-links/open`), which use the same key
//! shape.

use std::fmt;

use bech32::{Bech32m, Hrp};
use bip0039::{English, Mnemonic};
use secrecy::zeroize::Zeroize;
use zcash_keys::keys::{ReceiverRequirement, UnifiedAddressRequest, UnifiedSpendingKey};
use zcash_protocol::{
    consensus::{NetworkConstants, NetworkType, Parameters},
    value::{COIN, Zatoshis},
};
use zip32::{
    AccountId, ChildIndex,
    registered::{PathElement, SecretKey},
};

/// The origin of the links minted by this module.
pub const LINK_BASE: &str = "https://gift.zodl.com/";

/// The ZIP 32 context string for card secrets derived from a wallet seed.
pub const DERIVATION_CONTEXT: &[u8] = b"ZODL gift cards";

/// The ZIP under which card secrets are registered.
pub const DERIVATION_ZIP: u16 = 324;

/// The fee, in zatoshis, that a card is funded with on top of its face value so that
/// redeeming it does not reduce the face value (one ZIP 317 two-action transaction).
pub const CLAIM_FEE_RESERVE: u64 = 10_000;

/// The largest link this module will parse.
pub const MAX_LINK_LENGTH: usize = 16 * 1024;

/// The longest description, in UTF-8 bytes, that a link may carry.
pub const MAX_DESCRIPTION_BYTES: usize = 512;

const LINK_VERSION: &str = "1";
const VIZOR_LINK_BASE: &str = "https://link.vizor.cash/payment-links/open";

/// Errors produced while minting, reading or using a gift card.
///
/// Messages never include any part of the link, which carries a spending secret.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// The text is not a gift card link of any supported kind.
    NotAGiftLink,
    /// The link is a gift card link of a version this code does not read.
    UnsupportedVersion,
    /// A required field is missing.
    MissingField(&'static str),
    /// A field appears more than once.
    DuplicateField(&'static str),
    /// A field is present but malformed or out of range.
    InvalidField(&'static str),
    /// The link is for a network this code does not support.
    UnsupportedNetwork,
    /// The card is for a different network than the wallet using it.
    NetworkMismatch,
    /// The link is longer than [`MAX_LINK_LENGTH`].
    TooLong,
    /// The card's key could not be derived.
    KeyDerivation,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::NotAGiftLink => write!(f, "not a gift card link"),
            Error::UnsupportedVersion => write!(f, "unsupported gift card link version"),
            Error::MissingField(name) => write!(f, "gift card link is missing `{name}`"),
            Error::DuplicateField(name) => write!(f, "gift card link repeats `{name}`"),
            Error::InvalidField(name) => write!(f, "gift card link has an invalid `{name}`"),
            Error::UnsupportedNetwork => write!(f, "gift card link is for an unsupported network"),
            Error::NetworkMismatch => write!(f, "gift card is for a different network"),
            Error::TooLong => write!(f, "gift card link is too long"),
            Error::KeyDerivation => write!(f, "gift card key could not be derived"),
        }
    }
}

impl std::error::Error for Error {}

/// Who issued a gift card link.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Origin {
    /// A link in this module's own format.
    Zodl,
    /// A Vizor `v1` link.
    VizorV1,
    /// A Vizor `v2` link.
    VizorV2,
    /// A Vizor `v3` link.
    VizorV3,
}

/// The secret that controls a card: BIP 39 entropy, or (for older Vizor links) the
/// phrase itself.
enum Secret {
    Entropy(Vec<u8>),
    Phrase(String),
}

impl Drop for Secret {
    fn drop(&mut self) {
        match self {
            Secret::Entropy(bytes) => bytes.zeroize(),
            Secret::Phrase(phrase) => phrase.zeroize(),
        }
    }
}

/// A gift card read from, or ready to be written as, a link.
pub struct GiftCard {
    origin: Origin,
    network: NetworkType,
    secret: Secret,
    birthday_height: u32,
    amount: Option<Zatoshis>,
    description: Option<String>,
}

impl fmt::Debug for GiftCard {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GiftCard")
            .field("origin", &self.origin)
            .field("network", &self.network)
            .field("secret", &"<redacted>")
            .field("birthday_height", &self.birthday_height)
            .field("amount", &self.amount)
            .field("description", &self.description)
            .finish()
    }
}

/// Derives the secret of card `index` from a wallet seed.
pub fn derive_card_secret<P: Parameters>(
    params: &P,
    seed: &[u8],
    index: u32,
) -> Result<[u8; 32], Error> {
    if index >= (1 << 31) {
        return Err(Error::KeyDerivation);
    }
    let key = SecretKey::from_subpath(
        DERIVATION_CONTEXT,
        seed,
        DERIVATION_ZIP,
        &[
            PathElement::new(ChildIndex::hardened(params.network_type().coin_type()), &[]),
            PathElement::new(ChildIndex::hardened(index), &[]),
        ],
    )
    .map_err(|_| Error::KeyDerivation)?;
    Ok(*key.data())
}

impl GiftCard {
    /// Creates a card in this module's own format.
    pub fn new(
        network: NetworkType,
        secret: [u8; 32],
        birthday_height: u32,
        amount: Option<Zatoshis>,
        description: Option<String>,
    ) -> Result<Self, Error> {
        if birthday_height == 0 {
            return Err(Error::InvalidField("height"));
        }
        if let Some(text) = &description {
            check_description(text)?;
        }
        Ok(GiftCard {
            origin: Origin::Zodl,
            network,
            secret: Secret::Entropy(secret.to_vec()),
            birthday_height,
            amount,
            description,
        })
    }

    /// Reads a gift card link of any supported kind.
    pub fn parse(link: &str) -> Result<Self, Error> {
        let link = link.trim();
        if link.len() > MAX_LINK_LENGTH {
            return Err(Error::TooLong);
        }
        let (base, fragment) = link.split_once('#').ok_or(Error::NotAGiftLink)?;
        if is_zodl_base(base) {
            parse_zodl(fragment)
        } else if base.eq_ignore_ascii_case(VIZOR_LINK_BASE) {
            parse_vizor(fragment)
        } else {
            Err(Error::NotAGiftLink)
        }
    }

    /// Returns who issued the link.
    pub fn origin(&self) -> Origin {
        self.origin
    }

    /// Returns the network the card is on.
    pub fn network(&self) -> NetworkType {
        self.network
    }

    /// Returns the height from which to scan for the card's funds.
    pub fn birthday_height(&self) -> u32 {
        self.birthday_height
    }

    /// Returns the amount the link claims the card holds, if it states one.
    pub fn amount(&self) -> Option<Zatoshis> {
        self.amount
    }

    /// Returns the link's description or message, if any.
    pub fn description(&self) -> Option<&str> {
        self.description.as_deref()
    }

    /// Returns the 64-byte BIP 39 seed of the card wallet.
    pub fn seed(&self) -> Result<[u8; 64], Error> {
        let mnemonic = match &self.secret {
            Secret::Entropy(entropy) => Mnemonic::<English>::from_entropy(entropy.clone()),
            Secret::Phrase(phrase) => {
                let mut normalized = phrase.split_whitespace().collect::<Vec<_>>().join(" ");
                let mnemonic = Mnemonic::<English>::from_phrase(normalized.as_str());
                normalized.zeroize();
                mnemonic
            }
        }
        .map_err(|_| Error::KeyDerivation)?;
        Ok(mnemonic.to_seed(""))
    }

    /// Returns the spending key of the card wallet, checking that it is on the network
    /// of `params`.
    pub fn spending_key<P: Parameters>(&self, params: &P) -> Result<UnifiedSpendingKey, Error> {
        if params.network_type() != self.network {
            return Err(Error::NetworkMismatch);
        }
        let mut seed = self.seed()?;
        let usk = UnifiedSpendingKey::from_seed(params, &seed, AccountId::ZERO)
            .map_err(|_| Error::KeyDerivation);
        seed.zeroize();
        usk
    }

    /// Returns the Orchard-only address that a card is funded at.
    pub fn funding_address<P: Parameters>(&self, params: &P) -> Result<String, Error> {
        let ufvk = self.spending_key(params)?.to_unified_full_viewing_key();
        let request = UnifiedAddressRequest::custom(
            ReceiverRequirement::Require,
            ReceiverRequirement::Omit,
            ReceiverRequirement::Omit,
        )
        .map_err(|_| Error::KeyDerivation)?;
        let (address, _) = ufvk
            .default_address(request)
            .map_err(|_| Error::KeyDerivation)?;
        Ok(address.encode(params))
    }

    /// Writes the card as a link in this module's own format.
    ///
    /// Only cards created with [`GiftCard::new`] can be written.
    pub fn to_link(&self) -> Result<String, Error> {
        let entropy = match (&self.origin, &self.secret) {
            (Origin::Zodl, Secret::Entropy(entropy)) if entropy.len() == 32 => entropy,
            _ => return Err(Error::UnsupportedVersion),
        };
        let key = bech32::encode::<Bech32m>(key_hrp(self.network), entropy)
            .map_err(|_| Error::InvalidField("key"))?;
        let mut link = format!(
            "{LINK_BASE}#v={LINK_VERSION}&key={key}&height={}",
            self.birthday_height
        );
        if let Some(amount) = self.amount {
            link.push_str("&amount=");
            link.push_str(&format_zec(amount));
        }
        if let Some(text) = &self.description {
            link.push_str("&desc=");
            link.push_str(&percent_encode(text));
        }
        Ok(link)
    }
}

fn key_hrp(network: NetworkType) -> Hrp {
    Hrp::parse_unchecked(match network {
        NetworkType::Main => "zgift",
        NetworkType::Test => "zgifttest",
        NetworkType::Regtest => "zgiftregtest",
    })
}

fn is_zodl_base(base: &str) -> bool {
    let base = base.strip_suffix('/').unwrap_or(base);
    base.eq_ignore_ascii_case(LINK_BASE.trim_end_matches('/'))
}

fn parse_zodl(fragment: &str) -> Result<GiftCard, Error> {
    let mut version = None;
    let mut key = None;
    let mut height = None;
    let mut amount = None;
    let mut description = None;

    for pair in fragment.split('&') {
        let (name, value) = pair
            .split_once('=')
            .ok_or(Error::InvalidField("fragment"))?;
        let slot = match name {
            "v" => (&mut version, "v"),
            "key" => (&mut key, "key"),
            "height" => (&mut height, "height"),
            "amount" => (&mut amount, "amount"),
            "desc" => (&mut description, "desc"),
            // Unknown parameters are ignored so that later versions can add optional ones.
            _ => continue,
        };
        if slot.0.replace(value).is_some() {
            return Err(Error::DuplicateField(slot.1));
        }
    }

    if version.ok_or(Error::MissingField("v"))? != LINK_VERSION {
        return Err(Error::UnsupportedVersion);
    }

    let key = key.ok_or(Error::MissingField("key"))?;
    let (hrp, mut entropy) = bech32::decode(key).map_err(|_| Error::InvalidField("key"))?;
    // `bech32::decode` accepts either checksum; require Bech32m.
    if bech32::encode::<Bech32m>(hrp, &entropy).map_or(true, |k| !k.eq_ignore_ascii_case(key)) {
        entropy.zeroize();
        return Err(Error::InvalidField("key"));
    }
    let network = match hrp.as_str() {
        "zgift" => NetworkType::Main,
        "zgifttest" => NetworkType::Test,
        "zgiftregtest" => NetworkType::Regtest,
        _ => {
            entropy.zeroize();
            return Err(Error::UnsupportedNetwork);
        }
    };
    if entropy.len() != 32 {
        entropy.zeroize();
        return Err(Error::InvalidField("key"));
    }
    let secret = Secret::Entropy(entropy);

    let birthday_height = parse_height(height.ok_or(Error::MissingField("height"))?)?;
    let amount = amount.map(parse_zec).transpose()?;
    let description = description
        .map(|text| {
            let text = percent_decode(text).ok_or(Error::InvalidField("desc"))?;
            check_description(&text)?;
            Ok(text)
        })
        .transpose()?;

    Ok(GiftCard {
        origin: Origin::Zodl,
        network,
        secret,
        birthday_height,
        amount,
        description,
    })
}

fn parse_height(text: &str) -> Result<u32, Error> {
    if text.is_empty() || !text.bytes().all(|b| b.is_ascii_digit()) {
        return Err(Error::InvalidField("height"));
    }
    match text.parse::<u32>() {
        Ok(height) if height > 0 => Ok(height),
        _ => Err(Error::InvalidField("height")),
    }
}

fn check_description(text: &str) -> Result<(), Error> {
    if text.len() > MAX_DESCRIPTION_BYTES {
        Err(Error::InvalidField("desc"))
    } else {
        Ok(())
    }
}

/// Parses a decimal ZEC amount with at most eight fractional digits.
fn parse_zec(text: &str) -> Result<Zatoshis, Error> {
    let invalid = Error::InvalidField("amount");
    let (whole, fraction) = text.split_once('.').unwrap_or((text, ""));
    let digits = |s: &str| s.bytes().all(|b| b.is_ascii_digit());
    if whole.is_empty()
        || !digits(whole)
        || !digits(fraction)
        || fraction.len() > 8
        || (text.contains('.') && fraction.is_empty())
    {
        return Err(invalid);
    }
    let whole: u64 = whole.parse().map_err(|_| invalid.clone())?;
    let fraction: u64 = format!("{fraction:0<8}")
        .parse()
        .map_err(|_| invalid.clone())?;
    whole
        .checked_mul(COIN)
        .and_then(|z| z.checked_add(fraction))
        .and_then(|z| Zatoshis::from_u64(z).ok())
        .filter(|z| !z.is_zero())
        .ok_or(invalid)
}

fn format_zec(amount: Zatoshis) -> String {
    let zat = amount.into_u64();
    let fraction = format!("{:08}", zat % COIN);
    let fraction = fraction.trim_end_matches('0');
    if fraction.is_empty() {
        format!("{}", zat / COIN)
    } else {
        format!("{}.{fraction}", zat / COIN)
    }
}

fn percent_encode(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for b in text.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn percent_decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' => {
                let hex = text.get(i + 1..i + 3)?;
                out.push(u8::from_str_radix(hex, 16).ok()?);
                i += 3;
            }
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8(out).ok()
}

/// Decodes unpadded or padded base64url.
fn base64url_decode(text: &str) -> Option<Vec<u8>> {
    let text = text.trim_end_matches('=');
    let mut out = Vec::with_capacity(text.len() * 3 / 4);
    let mut acc = 0u32;
    let mut bits = 0;
    for c in text.bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'-' => 62,
            b'_' => 63,
            _ => return None,
        };
        acc = (acc << 6) | u32::from(v);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    // Reject a dangling sextet and non-canonical trailing bits.
    if bits >= 6 || acc != 0 {
        return None;
    }
    Some(out)
}

fn parse_vizor(fragment: &str) -> Result<GiftCard, Error> {
    let (origin, payload) = if let Some(p) = fragment.strip_prefix("v3=") {
        (Origin::VizorV3, p)
    } else if let Some(p) = fragment.strip_prefix("v2=") {
        (Origin::VizorV2, p)
    } else if let Some(p) = fragment.strip_prefix("v1=") {
        (Origin::VizorV1, p)
    } else {
        return Err(Error::UnsupportedVersion);
    };
    if payload.is_empty() || payload.contains('&') {
        return Err(Error::InvalidField("payload"));
    }
    let mut bytes = base64url_decode(payload).ok_or(Error::InvalidField("payload"))?;
    let json = serde_json::from_slice::<serde_json::Value>(&bytes);
    bytes.zeroize();
    let json = json.map_err(|_| Error::InvalidField("payload"))?;
    match origin {
        Origin::VizorV3 => parse_vizor_v3(json),
        _ => parse_vizor_object(origin, json),
    }
}

fn vizor_network(value: Option<&serde_json::Value>) -> Result<NetworkType, Error> {
    match value.and_then(|v| v.as_str()).map(str::trim) {
        Some("main") => Ok(NetworkType::Main),
        Some(_) => Err(Error::UnsupportedNetwork),
        None => Err(Error::MissingField("network")),
    }
}

fn vizor_u64(value: Option<&serde_json::Value>, name: &'static str) -> Result<u64, Error> {
    match value {
        Some(serde_json::Value::Number(n)) => n.as_u64().ok_or(Error::InvalidField(name)),
        Some(serde_json::Value::String(s)) => {
            let s = s.trim();
            if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
                return Err(Error::InvalidField(name));
            }
            s.parse().map_err(|_| Error::InvalidField(name))
        }
        Some(_) => Err(Error::InvalidField(name)),
        None => Err(Error::MissingField(name)),
    }
}

fn vizor_amount(value: Option<&serde_json::Value>) -> Result<Zatoshis, Error> {
    let zat = vizor_u64(value, "amount")?;
    Zatoshis::from_u64(zat)
        .ok()
        .filter(|z| !z.is_zero())
        .ok_or(Error::InvalidField("amount"))
}

fn vizor_height(value: Option<&serde_json::Value>) -> Result<u32, Error> {
    u32::try_from(vizor_u64(value, "height")?)
        .ok()
        .filter(|h| *h > 0)
        .ok_or(Error::InvalidField("height"))
}

fn vizor_text(value: Option<&serde_json::Value>) -> Option<String> {
    value
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|s| !s.is_empty() && s.len() <= MAX_DESCRIPTION_BYTES)
        .map(str::to_owned)
}

fn parse_vizor_object(origin: Origin, json: serde_json::Value) -> Result<GiftCard, Error> {
    let mut object = match json {
        serde_json::Value::Object(object) => object,
        _ => return Err(Error::InvalidField("payload")),
    };
    let expected = if origin == Origin::VizorV1 { 1 } else { 2 };
    if object.get("v").and_then(|v| v.as_u64()) != Some(expected) {
        return Err(Error::UnsupportedVersion);
    }
    let network = vizor_network(object.get("network"))?;
    let amount = vizor_amount(object.get("amountZatoshi"))?;
    let birthday_height = vizor_height(object.get("birthdayHeight"))?;
    let description = object
        .get("presentation")
        .and_then(|p| vizor_text(p.get("message")));
    let phrase = match object.remove("mnemonic") {
        Some(serde_json::Value::String(phrase)) => phrase,
        Some(_) => return Err(Error::InvalidField("mnemonic")),
        None => return Err(Error::MissingField("mnemonic")),
    };
    let card = GiftCard {
        origin,
        network,
        secret: Secret::Phrase(phrase),
        birthday_height,
        amount: Some(amount),
        description,
    };
    // Reject phrases that do not decode rather than failing later.
    card.seed().map(|mut seed| seed.zeroize())?;
    Ok(card)
}

fn parse_vizor_v3(json: serde_json::Value) -> Result<GiftCard, Error> {
    let mut items = match json {
        serde_json::Value::Array(items) if (4..=8).contains(&items.len()) => items,
        _ => return Err(Error::InvalidField("payload")),
    };
    let network = vizor_network(items.first())?;
    let birthday_height = vizor_height(items.get(2))?;
    let amount = match items.get(3) {
        Some(serde_json::Value::String(_)) => vizor_amount(items.get(3))?,
        _ => return Err(Error::InvalidField("amount")),
    };
    let description = vizor_text(items.get(6));
    let entropy = match std::mem::take(&mut items[1]) {
        serde_json::Value::String(mut encoded) => {
            let entropy = base64url_decode(&encoded);
            encoded.zeroize();
            entropy.ok_or(Error::InvalidField("key"))?
        }
        _ => return Err(Error::InvalidField("key")),
    };
    if !matches!(entropy.len(), 16 | 20 | 24 | 28 | 32) {
        let mut entropy = entropy;
        entropy.zeroize();
        return Err(Error::InvalidField("key"));
    }
    Ok(GiftCard {
        origin: Origin::VizorV3,
        network,
        secret: Secret::Entropy(entropy),
        birthday_height,
        amount: Some(amount),
        description,
    })
}

#[cfg(test)]
mod tests {
    use zcash_protocol::consensus::{MAIN_NETWORK, TEST_NETWORK};

    use super::*;

    // Vizor's published, never-funded reference vector (32 zero bytes of entropy).
    const VIZOR_V3: &str = "https://link.vizor.cash/payment-links/open#v3=WyJtYWluIiwiQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQSIsMzQ4MzE0MSwiMTAwMDAwMCIsImtuaWdodE1hZ2ljIiwxMS4xNzQ3LCJJdCdzIGEgZ3JlYXQgZGF5IHRvIHNoaWVsZCB5b3VyIFpFQyDwn5uh77iPIl0";

    #[test]
    fn zodl_link_round_trip() {
        let secret = derive_card_secret(&TEST_NETWORK, &[7; 32], 5).unwrap();
        let card = GiftCard::new(
            NetworkType::Test,
            secret,
            4_000_000,
            Some(Zatoshis::from_u64(12_340_000).unwrap()),
            Some("Hi from Zcash Summit!".into()),
        )
        .unwrap();
        let link = card.to_link().unwrap();
        assert!(link.starts_with("https://gift.zodl.com/#v=1&key=zgifttest1"));
        assert!(link.ends_with("&height=4000000&amount=0.1234&desc=Hi%20from%20Zcash%20Summit%21"));

        let parsed = GiftCard::parse(&link).unwrap();
        assert_eq!(parsed.origin(), Origin::Zodl);
        assert_eq!(parsed.network(), NetworkType::Test);
        assert_eq!(parsed.birthday_height(), 4_000_000);
        assert_eq!(parsed.amount(), card.amount());
        assert_eq!(parsed.description(), Some("Hi from Zcash Summit!"));
        assert_eq!(parsed.seed().unwrap(), card.seed().unwrap());
        assert_eq!(
            parsed.funding_address(&TEST_NETWORK).unwrap(),
            card.funding_address(&TEST_NETWORK).unwrap()
        );
        assert_eq!(
            parsed.spending_key(&MAIN_NETWORK).unwrap_err(),
            Error::NetworkMismatch
        );
    }

    #[test]
    fn minimal_zodl_link() {
        let card = GiftCard::new(NetworkType::Main, [1; 32], 3_500_000, None, None).unwrap();
        let link = card.to_link().unwrap();
        let parsed = GiftCard::parse(&link).unwrap();
        assert_eq!(parsed.amount(), None);
        assert_eq!(parsed.description(), None);
        assert_eq!(parsed.network(), NetworkType::Main);
        // A trailing slash on the origin is optional and the origin is case-insensitive.
        let bare = link.replacen("https://gift.zodl.com/", "HTTPS://Gift.Zodl.com", 1);
        assert_eq!(
            GiftCard::parse(&bare).unwrap().seed().unwrap(),
            card.seed().unwrap()
        );
    }

    #[test]
    fn rejects_malformed_zodl_links() {
        let link = GiftCard::new(NetworkType::Main, [1; 32], 3_500_000, None, None)
            .unwrap()
            .to_link()
            .unwrap();
        let (base, fragment) = link.split_once('#').unwrap();
        let key = fragment.split('&').nth(1).unwrap();
        let cases = [
            (
                format!("{base}#v=2&{key}&height=1"),
                Error::UnsupportedVersion,
            ),
            (format!("{base}#{key}&height=1"), Error::MissingField("v")),
            (format!("{base}#v=1&height=1"), Error::MissingField("key")),
            (format!("{base}#v=1&{key}"), Error::MissingField("height")),
            (
                format!("{base}#v=1&{key}&height=0"),
                Error::InvalidField("height"),
            ),
            (
                format!("{base}#v=1&{key}&height=1&height=2"),
                Error::DuplicateField("height"),
            ),
            (
                format!("{base}#v=1&{key}&height=1&amount=0"),
                Error::InvalidField("amount"),
            ),
            (
                format!("{base}#v=1&{key}&height=1&amount=1."),
                Error::InvalidField("amount"),
            ),
            (
                format!("{base}#v=1&{key}&height=1&amount=0.123456789"),
                Error::InvalidField("amount"),
            ),
            (
                format!("{base}#v=1&{}x&height=1", key),
                Error::InvalidField("key"),
            ),
            ("https://example.com/#v=1".to_string(), Error::NotAGiftLink),
            (base.to_string(), Error::NotAGiftLink),
        ];
        for (text, error) in cases {
            assert_eq!(GiftCard::parse(&text).unwrap_err(), error, "{text}");
        }
        // Unknown optional parameters are ignored.
        assert!(GiftCard::parse(&format!("{link}&future=1")).is_ok());
    }

    #[test]
    fn derivation_is_per_index_and_network() {
        let seed = [3u8; 32];
        let a = derive_card_secret(&MAIN_NETWORK, &seed, 0).unwrap();
        let b = derive_card_secret(&MAIN_NETWORK, &seed, 1).unwrap();
        let c = derive_card_secret(&TEST_NETWORK, &seed, 0).unwrap();
        assert_ne!(a, b);
        assert_ne!(a, c);
        assert_eq!(a, derive_card_secret(&MAIN_NETWORK, &seed, 0).unwrap());
        assert!(derive_card_secret(&MAIN_NETWORK, &seed, 1 << 31).is_err());
    }

    /// The BIP 39 English test vector (passphrase `TREZOR`) and the mainnet Orchard-only
    /// address that Vizor's own key-derivation tests expect for it. Vizor cards are claimed
    /// through `spending_key`/`funding_address`, so these must agree on the derivation path
    /// (ZIP 32 account 0, Orchard receiver at the default diversifier).
    #[test]
    fn orchard_derivation_matches_vizor_bip39_vector() {
        const PHRASE: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        const VIZOR_UA: &str = "u16yrmgarlnpx3ktaxq4l8mmc8wwnw3nmml02nujwghr2enf3jggmfjqax44yqts3csnxrtq8pyshk9ryew2zlrp3x5lyc64usqsnwnu0v";
        let seed = Mnemonic::<English>::from_phrase(PHRASE)
            .unwrap()
            .to_seed("TREZOR");
        let ufvk = UnifiedSpendingKey::from_seed(&MAIN_NETWORK, &seed, AccountId::ZERO)
            .unwrap()
            .to_unified_full_viewing_key();
        let request = UnifiedAddressRequest::custom(
            ReceiverRequirement::Require,
            ReceiverRequirement::Omit,
            ReceiverRequirement::Omit,
        )
        .unwrap();
        let (address, _) = ufvk.default_address(request).unwrap();
        assert_eq!(address.encode(&MAIN_NETWORK), VIZOR_UA);
    }

    #[test]
    fn reads_vizor_v3() {
        let card = GiftCard::parse(VIZOR_V3).unwrap();
        assert_eq!(card.origin(), Origin::VizorV3);
        assert_eq!(card.network(), NetworkType::Main);
        assert_eq!(card.birthday_height(), 3_483_141);
        assert_eq!(card.amount(), Some(Zatoshis::from_u64(1_000_000).unwrap()));
        assert_eq!(
            card.description(),
            Some("It's a great day to shield your ZEC 🛡️")
        );
        // 32 zero bytes of entropy is "abandon" x23 + "art".
        let phrase = format!("{} art", ["abandon"; 23].join(" "));
        let expected = Mnemonic::<English>::from_phrase(phrase.as_str())
            .unwrap()
            .to_seed("");
        assert_eq!(card.seed().unwrap(), expected);
        assert!(card.to_link().is_err());
    }

    #[test]
    fn reads_vizor_v2_and_v1() {
        fn b64(bytes: &[u8]) -> String {
            const ALPHABET: &[u8] =
                b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
            let mut out = String::new();
            for chunk in bytes.chunks(3) {
                let n = chunk.iter().fold(0u32, |acc, b| (acc << 8) | u32::from(*b))
                    << (8 * (3 - chunk.len()));
                for i in 0..=chunk.len() {
                    out.push(ALPHABET[((n >> (18 - 6 * i)) & 63) as usize] as char);
                }
            }
            out
        }
        let phrase = format!("{}  art", ["abandon"; 23].join(" "));
        let v2 = serde_json::json!({
            "v": 2, "network": "main", "amountZatoshi": "2500000", "mnemonic": phrase,
            "birthdayHeight": 3_400_000, "label": "Payment link",
            "presentation": {"message": "gm"},
        });
        let card = GiftCard::parse(&format!(
            "{VIZOR_LINK_BASE}#v2={}",
            b64(v2.to_string().as_bytes())
        ))
        .unwrap();
        assert_eq!(card.origin(), Origin::VizorV2);
        assert_eq!(card.amount(), Some(Zatoshis::from_u64(2_500_000).unwrap()));
        assert_eq!(card.birthday_height(), 3_400_000);
        assert_eq!(card.description(), Some("gm"));
        assert_eq!(
            card.seed().unwrap(),
            GiftCard::parse(VIZOR_V3).unwrap().seed().unwrap()
        );

        let v1 = serde_json::json!({
            "v": 1, "network": "main", "amountZatoshi": 1, "mnemonic": phrase,
            "birthdayHeight": "3400000", "label": "", "address": "u1x", "createdAt": "2026-01-01T00:00:00Z",
        });
        let card = GiftCard::parse(&format!(
            "{VIZOR_LINK_BASE}#v1={}",
            b64(v1.to_string().as_bytes())
        ))
        .unwrap();
        assert_eq!(card.origin(), Origin::VizorV1);

        // A version tag that does not match the fragment prefix is refused.
        let link = format!("{VIZOR_LINK_BASE}#v1={}", b64(v2.to_string().as_bytes()));
        assert_eq!(
            GiftCard::parse(&link).unwrap_err(),
            Error::UnsupportedVersion
        );

        // Test-network Vizor links are refused.
        let mut testnet = v2.clone();
        testnet["network"] = "test".into();
        let link = format!(
            "{VIZOR_LINK_BASE}#v2={}",
            b64(testnet.to_string().as_bytes())
        );
        assert_eq!(
            GiftCard::parse(&link).unwrap_err(),
            Error::UnsupportedNetwork
        );
    }

    #[test]
    fn debug_output_redacts_the_secret() {
        let card = GiftCard::parse(VIZOR_V3).unwrap();
        let debug = format!("{card:?}");
        assert!(debug.contains("<redacted>"));
        assert!(!debug.contains("AAAA"));
    }
}
