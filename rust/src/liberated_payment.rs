//! Liberated payments (ZIP 324): payments encapsulated in a URI that carries the key of a
//! small, single-purpose wallet.
//!
//! A *minter* creates a *payment secret*, funds the *payment wallet* derived from it, and
//! hands the secret to a *claimant* inside a link. The claimant imports the payment wallet
//! and sweeps its funds into a wallet of their own. Nothing about the payment is tied to
//! the host that serves the link: the secret travels in the URI fragment, which browsers
//! never send to the server.
//!
//! A payment secret is 32 bytes: the entropy of a 24-word English BIP 39 phrase. The
//! payment wallet is ZIP 32 account 0 of that phrase's seed (empty passphrase), and funds
//! are sent to its Orchard-only default address. Any wallet that can restore a phrase can
//! therefore recover a payment.
//!
//! Secrets minted from a wallet are derived from that wallet's seed with ZIP 32 registered
//! key derivation under ZIP 324, so a minter can always rederive (and reclaim) payments
//! that were never claimed:
//!
//! ```text
//! secret_i = registered::SecretKey::from_subpath("Zcash_URIEncapsulatedPayment", seed, 324,
//!                                                [coin_type', i']).data()
//! ```
//!
//! A payment is shared as a link whose fragment carries the secret:
//!
//! ```text
//! https://<host>#v=1&key=<bech32m secret>&height=<birthday>[&amount=<ZEC>][&desc=<text>]
//! ```
//!
//! The Bech32m human-readable part of `key` (`zgift`, `zgifttest` or `zgiftregtest`)
//! selects the network. `height` is a block height at or below the height of the
//! transaction that funded the payment, from which a wallet scans for its funds. `amount`
//! and `desc` are informational; the funds found on chain are authoritative.
//!
//! This module also reads a legacy JSON/base64url encoding found in the wild at
//! `/payment-links/open#vN=` (`v1`, `v2` and `v3` payloads), which uses the same key shape.

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

/// The ZIP 32 context string for payment secrets derived from a wallet seed.
pub const DERIVATION_CONTEXT: &[u8] = b"Zcash_URIEncapsulatedPayment";

/// The ZIP under which payment secrets are registered.
pub const DERIVATION_ZIP: u16 = 324;

/// The fee, in zatoshis, that a payment is funded with on top of its face value so that
/// claiming it does not reduce the face value (one ZIP 317 two-action transaction).
pub const CLAIM_FEE_RESERVE: u64 = 10_000;

/// The largest link this module will parse.
pub const MAX_LINK_LENGTH: usize = 16 * 1024;

/// The longest description, in UTF-8 bytes, that a link may carry.
pub const MAX_DESCRIPTION_BYTES: usize = 512;

const LINK_VERSION: &str = "1";

/// Errors produced while minting, reading or using a liberated payment.
///
/// Messages never include any part of the link, which carries a spending secret.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// The text is not a liberated payment link of any supported kind.
    NotAPaymentLink,
    /// The link is a liberated payment link of a version this code does not read.
    UnsupportedVersion,
    /// A required field is missing.
    MissingField(&'static str),
    /// A field appears more than once.
    DuplicateField(&'static str),
    /// A field is present but malformed or out of range.
    InvalidField(&'static str),
    /// The link is for a network this code does not support.
    UnsupportedNetwork,
    /// The payment is for a different network than the wallet using it.
    NetworkMismatch,
    /// The link is longer than [`MAX_LINK_LENGTH`].
    TooLong,
    /// The payment's key could not be derived.
    KeyDerivation,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::NotAPaymentLink => write!(f, "not a liberated payment link"),
            Error::UnsupportedVersion => write!(f, "unsupported payment link version"),
            Error::MissingField(name) => write!(f, "payment link is missing `{name}`"),
            Error::DuplicateField(name) => write!(f, "payment link repeats `{name}`"),
            Error::InvalidField(name) => write!(f, "payment link has an invalid `{name}`"),
            Error::UnsupportedNetwork => write!(f, "payment link is for an unsupported network"),
            Error::NetworkMismatch => write!(f, "payment is for a different network"),
            Error::TooLong => write!(f, "payment link is too long"),
            Error::KeyDerivation => write!(f, "payment key could not be derived"),
        }
    }
}

impl std::error::Error for Error {}

/// The encoding a liberated payment link was read from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Origin {
    /// A `v=1` link in the format described at the top of this module.
    V1,
    /// A legacy `v1=` JSON payload.
    LegacyV1,
    /// A legacy `v2=` JSON payload.
    LegacyV2,
    /// A legacy `v3=` JSON payload.
    LegacyV3,
}

impl Origin {
    /// Returns a stable, machine-readable name for the origin.
    pub fn as_str(self) -> &'static str {
        match self {
            Origin::V1 => "v1",
            Origin::LegacyV1 => "legacy-v1",
            Origin::LegacyV2 => "legacy-v2",
            Origin::LegacyV3 => "legacy-v3",
        }
    }
}

/// The secret that controls a payment wallet: BIP 39 entropy, or (for older legacy links)
/// the phrase itself.
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

/// A liberated payment read from, or ready to be written as, a link.
pub struct LiberatedPayment {
    origin: Origin,
    network: NetworkType,
    secret: Secret,
    birthday_height: u32,
    amount: Option<Zatoshis>,
    description: Option<String>,
}

impl fmt::Debug for LiberatedPayment {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LiberatedPayment")
            .field("origin", &self.origin)
            .field("network", &self.network)
            .field("secret", &"<redacted>")
            .field("birthday_height", &self.birthday_height)
            .field("amount", &self.amount)
            .field("description", &self.description)
            .finish()
    }
}

/// Derives the secret of payment `index` from a minter's wallet seed.
pub fn derive_payment_secret<P: Parameters>(
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

impl LiberatedPayment {
    /// Creates a payment in the `v=1` format.
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
        Ok(LiberatedPayment {
            origin: Origin::V1,
            network,
            secret: Secret::Entropy(secret.to_vec()),
            birthday_height,
            amount,
            description,
        })
    }

    /// Reads a liberated payment link of any supported kind.
    ///
    /// The link must be an `https` URL. The encoding is selected by the fragment: a
    /// legacy `vN=<payload>` fragment, or the `v=1&key=…` form otherwise.
    pub fn parse(link: &str) -> Result<Self, Error> {
        let link = link.trim();
        if link.len() > MAX_LINK_LENGTH {
            return Err(Error::TooLong);
        }
        let (base, fragment) = link.split_once('#').ok_or(Error::NotAPaymentLink)?;
        check_host(base).map_err(|_| Error::NotAPaymentLink)?;
        if is_legacy_fragment(fragment) {
            parse_legacy(fragment)
        } else {
            parse_v1(fragment)
        }
    }

    /// Returns the encoding the link was read from.
    pub fn origin(&self) -> Origin {
        self.origin
    }

    /// Returns the network the payment is on.
    pub fn network(&self) -> NetworkType {
        self.network
    }

    /// Returns the height from which to scan for the payment's funds.
    pub fn birthday_height(&self) -> u32 {
        self.birthday_height
    }

    /// Returns the amount the link claims the payment holds, if it states one.
    pub fn amount(&self) -> Option<Zatoshis> {
        self.amount
    }

    /// Returns the link's description or message, if any.
    pub fn description(&self) -> Option<&str> {
        self.description.as_deref()
    }

    /// Returns the 64-byte BIP 39 seed of the payment wallet.
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

    /// Returns the spending key of the payment wallet, checking that it is on the network
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

    /// Returns the Orchard-only address that a payment is funded at.
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

    /// Writes the payment as a `v=1` link on `host`, an `https` URL (such as
    /// `https://example.com/`) whose fragment will carry the payment.
    ///
    /// Only payments created with [`LiberatedPayment::new`] can be written.
    pub fn to_link(&self, host: &str) -> Result<String, Error> {
        let host = check_host(host)?;
        // `https://example.com#…` is a valid URL, but browsers and link matchers normalise it
        // to `https://example.com/#…`; write the normalised form so every consumer sees one shape.
        let separator = if host[8..].contains('/') { "" } else { "/" };
        let entropy = match (&self.origin, &self.secret) {
            (Origin::V1, Secret::Entropy(entropy)) if entropy.len() == 32 => entropy,
            _ => return Err(Error::UnsupportedVersion),
        };
        let key = bech32::encode::<Bech32m>(key_hrp(self.network), entropy)
            .map_err(|_| Error::InvalidField("key"))?;
        let mut link = format!(
            "{host}{separator}#v={LINK_VERSION}&key={key}&height={}",
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

/// Checks that `host` is an `https` URL without a fragment, returning it trimmed.
pub fn check_host(host: &str) -> Result<&str, Error> {
    let host = host.trim();
    let rest = host
        .get(..8)
        .filter(|scheme| scheme.eq_ignore_ascii_case("https://"))
        .map(|_| &host[8..])
        .ok_or(Error::InvalidField("host"))?;
    if rest.is_empty()
        || rest.starts_with('/')
        || host.contains('#')
        || host.chars().any(char::is_whitespace)
    {
        return Err(Error::InvalidField("host"));
    }
    Ok(host)
}

fn key_hrp(network: NetworkType) -> Hrp {
    Hrp::parse_unchecked(match network {
        NetworkType::Main => "zgift",
        NetworkType::Test => "zgifttest",
        NetworkType::Regtest => "zgiftregtest",
    })
}

fn is_legacy_fragment(fragment: &str) -> bool {
    ["v1=", "v2=", "v3="]
        .iter()
        .any(|prefix| fragment.starts_with(prefix))
}

fn parse_v1(fragment: &str) -> Result<LiberatedPayment, Error> {
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

    Ok(LiberatedPayment {
        origin: Origin::V1,
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

fn parse_legacy(fragment: &str) -> Result<LiberatedPayment, Error> {
    let (origin, payload) = if let Some(p) = fragment.strip_prefix("v3=") {
        (Origin::LegacyV3, p)
    } else if let Some(p) = fragment.strip_prefix("v2=") {
        (Origin::LegacyV2, p)
    } else if let Some(p) = fragment.strip_prefix("v1=") {
        (Origin::LegacyV1, p)
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
        Origin::LegacyV3 => parse_legacy_v3(json),
        _ => parse_legacy_object(origin, json),
    }
}

fn legacy_network(value: Option<&serde_json::Value>) -> Result<NetworkType, Error> {
    match value.and_then(|v| v.as_str()).map(str::trim) {
        Some("main") => Ok(NetworkType::Main),
        Some(_) => Err(Error::UnsupportedNetwork),
        None => Err(Error::MissingField("network")),
    }
}

fn legacy_u64(value: Option<&serde_json::Value>, name: &'static str) -> Result<u64, Error> {
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

fn legacy_amount(value: Option<&serde_json::Value>) -> Result<Zatoshis, Error> {
    let zat = legacy_u64(value, "amount")?;
    Zatoshis::from_u64(zat)
        .ok()
        .filter(|z| !z.is_zero())
        .ok_or(Error::InvalidField("amount"))
}

fn legacy_height(value: Option<&serde_json::Value>) -> Result<u32, Error> {
    u32::try_from(legacy_u64(value, "height")?)
        .ok()
        .filter(|h| *h > 0)
        .ok_or(Error::InvalidField("height"))
}

fn legacy_text(value: Option<&serde_json::Value>) -> Option<String> {
    value
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|s| !s.is_empty() && s.len() <= MAX_DESCRIPTION_BYTES)
        .map(str::to_owned)
}

fn parse_legacy_object(origin: Origin, json: serde_json::Value) -> Result<LiberatedPayment, Error> {
    let mut object = match json {
        serde_json::Value::Object(object) => object,
        _ => return Err(Error::InvalidField("payload")),
    };
    let expected = if origin == Origin::LegacyV1 { 1 } else { 2 };
    if object.get("v").and_then(|v| v.as_u64()) != Some(expected) {
        return Err(Error::UnsupportedVersion);
    }
    let network = legacy_network(object.get("network"))?;
    let amount = legacy_amount(object.get("amountZatoshi"))?;
    let birthday_height = legacy_height(object.get("birthdayHeight"))?;
    let description = object
        .get("presentation")
        .and_then(|p| legacy_text(p.get("message")));
    let phrase = match object.remove("mnemonic") {
        Some(serde_json::Value::String(phrase)) => phrase,
        Some(_) => return Err(Error::InvalidField("mnemonic")),
        None => return Err(Error::MissingField("mnemonic")),
    };
    let payment = LiberatedPayment {
        origin,
        network,
        secret: Secret::Phrase(phrase),
        birthday_height,
        amount: Some(amount),
        description,
    };
    // Reject phrases that do not decode rather than failing later.
    payment.seed().map(|mut seed| seed.zeroize())?;
    Ok(payment)
}

fn parse_legacy_v3(json: serde_json::Value) -> Result<LiberatedPayment, Error> {
    let mut items = match json {
        serde_json::Value::Array(items) if (4..=8).contains(&items.len()) => items,
        _ => return Err(Error::InvalidField("payload")),
    };
    let network = legacy_network(items.first())?;
    let birthday_height = legacy_height(items.get(2))?;
    let amount = match items.get(3) {
        Some(serde_json::Value::String(_)) => legacy_amount(items.get(3))?,
        _ => return Err(Error::InvalidField("amount")),
    };
    let description = legacy_text(items.get(6));
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
    Ok(LiberatedPayment {
        origin: Origin::LegacyV3,
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

    const HOST: &str = "https://example.com/";
    const LEGACY_LINK_BASE: &str = "https://legacy.example/payment-links/open";

    // A published, never-funded reference vector of the legacy `v3` encoding (32 zero
    // bytes of entropy).
    const LEGACY_V3: &str = "https://legacy.example/payment-links/open#v3=WyJtYWluIiwiQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQSIsMzQ4MzE0MSwiMTAwMDAwMCIsImtuaWdodE1hZ2ljIiwxMS4xNzQ3LCJJdCdzIGEgZ3JlYXQgZGF5IHRvIHNoaWVsZCB5b3VyIFpFQyDwn5uh77iPIl0";

    #[test]
    fn v1_link_round_trip() {
        let secret = derive_payment_secret(&TEST_NETWORK, &[7; 32], 5).unwrap();
        let payment = LiberatedPayment::new(
            NetworkType::Test,
            secret,
            4_000_000,
            Some(Zatoshis::from_u64(12_340_000).unwrap()),
            Some("Hi from Zcash!".into()),
        )
        .unwrap();
        let link = payment.to_link(HOST).unwrap();
        assert!(link.starts_with("https://example.com/#v=1&key=zgifttest1"));
        // A bare host is written with the `/` that browsers add; a path is left alone.
        let bare = payment.to_link("https://example.com").unwrap();
        assert!(bare.starts_with("https://example.com/#v=1&key=zgifttest1"));
        let with_path = payment.to_link("https://example.com/claim").unwrap();
        assert!(with_path.starts_with("https://example.com/claim#v=1&key=zgifttest1"));
        assert!(link.ends_with("&height=4000000&amount=0.1234&desc=Hi%20from%20Zcash%21"));

        let parsed = LiberatedPayment::parse(&link).unwrap();
        assert_eq!(parsed.origin(), Origin::V1);
        assert_eq!(parsed.network(), NetworkType::Test);
        assert_eq!(parsed.birthday_height(), 4_000_000);
        assert_eq!(parsed.amount(), payment.amount());
        assert_eq!(parsed.description(), Some("Hi from Zcash!"));
        assert_eq!(parsed.seed().unwrap(), payment.seed().unwrap());
        assert_eq!(
            parsed.funding_address(&TEST_NETWORK).unwrap(),
            payment.funding_address(&TEST_NETWORK).unwrap()
        );
        assert_eq!(
            parsed.spending_key(&MAIN_NETWORK).unwrap_err(),
            Error::NetworkMismatch
        );
    }

    #[test]
    fn minimal_v1_link() {
        let payment =
            LiberatedPayment::new(NetworkType::Main, [1; 32], 3_500_000, None, None).unwrap();
        let link = payment.to_link(HOST).unwrap();
        let parsed = LiberatedPayment::parse(&link).unwrap();
        assert_eq!(parsed.amount(), None);
        assert_eq!(parsed.description(), None);
        assert_eq!(parsed.network(), NetworkType::Main);
        // The host is not part of the payment: any `https` URL carries it.
        let moved = link.replacen(HOST, "HTTPS://Pay.Example.org/claim", 1);
        assert_eq!(
            LiberatedPayment::parse(&moved).unwrap().seed().unwrap(),
            payment.seed().unwrap()
        );
    }

    #[test]
    fn hosts_are_https_urls_without_a_fragment() {
        let payment =
            LiberatedPayment::new(NetworkType::Main, [1; 32], 3_500_000, None, None).unwrap();
        for host in ["https://example.com", " https://example.com/pay?x=1 "] {
            assert_eq!(check_host(host).unwrap(), host.trim());
            assert!(payment.to_link(host).unwrap().starts_with(host.trim()));
        }
        for host in [
            "http://example.com/",
            "https://",
            "https:///path",
            "https://example.com/#v=1",
            "https://exa mple.com/",
            "example.com",
        ] {
            assert_eq!(
                payment.to_link(host).unwrap_err(),
                Error::InvalidField("host"),
                "{host}"
            );
        }
    }

    #[test]
    fn rejects_malformed_v1_links() {
        let link = LiberatedPayment::new(NetworkType::Main, [1; 32], 3_500_000, None, None)
            .unwrap()
            .to_link(HOST)
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
            (
                format!("http://example.com/#{fragment}"),
                Error::NotAPaymentLink,
            ),
            (fragment.to_string(), Error::NotAPaymentLink),
            (base.to_string(), Error::NotAPaymentLink),
        ];
        for (text, error) in cases {
            assert_eq!(LiberatedPayment::parse(&text).unwrap_err(), error, "{text}");
        }
        // Unknown optional parameters are ignored.
        assert!(LiberatedPayment::parse(&format!("{link}&future=1")).is_ok());
    }

    #[test]
    fn derivation_is_per_index_and_network() {
        let seed = [3u8; 32];
        let a = derive_payment_secret(&MAIN_NETWORK, &seed, 0).unwrap();
        let b = derive_payment_secret(&MAIN_NETWORK, &seed, 1).unwrap();
        let c = derive_payment_secret(&TEST_NETWORK, &seed, 0).unwrap();
        assert_ne!(a, b);
        assert_ne!(a, c);
        assert_eq!(a, derive_payment_secret(&MAIN_NETWORK, &seed, 0).unwrap());
        assert!(derive_payment_secret(&MAIN_NETWORK, &seed, 1 << 31).is_err());
    }

    /// Pins the registered-derivation context string: a change to it changes every
    /// payment secret, so this vector must only move together with the ZIP.
    #[test]
    fn derivation_vector() {
        let seed = [0u8; 32];
        assert_eq!(
            hex::encode(derive_payment_secret(&MAIN_NETWORK, &seed, 0).unwrap()),
            "e3d460242ab6029c0665a900cc8622665ed37e8cd10ae5cf6d2a67be86690792"
        );
        assert_eq!(
            hex::encode(derive_payment_secret(&TEST_NETWORK, &seed, 1).unwrap()),
            "5c7eeb4332d0d1797b0f25ed998d00779ea692cec9db8741ba20f9c7b383a21a"
        );
    }

    /// The BIP 39 English test vector (passphrase `TREZOR`) and the mainnet Orchard-only
    /// address that the derivation expected by other implementations of the legacy encoding
    /// yields for it. Legacy payments are claimed through `spending_key`/`funding_address`,
    /// so these must agree on the derivation path (ZIP 32 account 0, Orchard receiver at
    /// the default diversifier).
    #[test]
    fn orchard_derivation_matches_legacy_bip39_vector() {
        const PHRASE: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        const LEGACY_UA: &str = "u16yrmgarlnpx3ktaxq4l8mmc8wwnw3nmml02nujwghr2enf3jggmfjqax44yqts3csnxrtq8pyshk9ryew2zlrp3x5lyc64usqsnwnu0v";
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
        assert_eq!(address.encode(&MAIN_NETWORK), LEGACY_UA);
    }

    #[test]
    fn reads_legacy_v3() {
        let payment = LiberatedPayment::parse(LEGACY_V3).unwrap();
        assert_eq!(payment.origin(), Origin::LegacyV3);
        assert_eq!(payment.network(), NetworkType::Main);
        assert_eq!(payment.birthday_height(), 3_483_141);
        assert_eq!(
            payment.amount(),
            Some(Zatoshis::from_u64(1_000_000).unwrap())
        );
        assert_eq!(
            payment.description(),
            Some("It's a great day to shield your ZEC 🛡️")
        );
        // 32 zero bytes of entropy is "abandon" x23 + "art".
        let phrase = format!("{} art", ["abandon"; 23].join(" "));
        let expected = Mnemonic::<English>::from_phrase(phrase.as_str())
            .unwrap()
            .to_seed("");
        assert_eq!(payment.seed().unwrap(), expected);
        assert!(payment.to_link(HOST).is_err());
    }

    #[test]
    fn reads_legacy_v2_and_v1() {
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
        let payment = LiberatedPayment::parse(&format!(
            "{LEGACY_LINK_BASE}#v2={}",
            b64(v2.to_string().as_bytes())
        ))
        .unwrap();
        assert_eq!(payment.origin(), Origin::LegacyV2);
        assert_eq!(
            payment.amount(),
            Some(Zatoshis::from_u64(2_500_000).unwrap())
        );
        assert_eq!(payment.birthday_height(), 3_400_000);
        assert_eq!(payment.description(), Some("gm"));
        assert_eq!(
            payment.seed().unwrap(),
            LiberatedPayment::parse(LEGACY_V3).unwrap().seed().unwrap()
        );

        let v1 = serde_json::json!({
            "v": 1, "network": "main", "amountZatoshi": 1, "mnemonic": phrase,
            "birthdayHeight": "3400000", "label": "", "address": "u1x", "createdAt": "2026-01-01T00:00:00Z",
        });
        let payment = LiberatedPayment::parse(&format!(
            "{LEGACY_LINK_BASE}#v1={}",
            b64(v1.to_string().as_bytes())
        ))
        .unwrap();
        assert_eq!(payment.origin(), Origin::LegacyV1);

        // A version tag that does not match the fragment prefix is refused.
        let link = format!("{LEGACY_LINK_BASE}#v1={}", b64(v2.to_string().as_bytes()));
        assert_eq!(
            LiberatedPayment::parse(&link).unwrap_err(),
            Error::UnsupportedVersion
        );

        // Test-network legacy links are refused.
        let mut testnet = v2.clone();
        testnet["network"] = "test".into();
        let link = format!(
            "{LEGACY_LINK_BASE}#v2={}",
            b64(testnet.to_string().as_bytes())
        );
        assert_eq!(
            LiberatedPayment::parse(&link).unwrap_err(),
            Error::UnsupportedNetwork
        );
    }

    #[test]
    fn origin_names_are_stable() {
        assert_eq!(Origin::V1.as_str(), "v1");
        assert_eq!(Origin::LegacyV1.as_str(), "legacy-v1");
        assert_eq!(Origin::LegacyV2.as_str(), "legacy-v2");
        assert_eq!(Origin::LegacyV3.as_str(), "legacy-v3");
    }

    #[test]
    fn debug_output_redacts_the_secret() {
        let payment = LiberatedPayment::parse(LEGACY_V3).unwrap();
        let debug = format!("{payment:?}");
        assert!(debug.contains("<redacted>"));
        assert!(!debug.contains("AAAA"));
    }
}
