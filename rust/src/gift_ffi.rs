//! The C surface for reading gift card links (see [`crate::liberated_payment`]).
//!
//! A gift card is a liberated payment (ZIP 324) as the SDK presents it to apps. Parsing is
//! stateless: it touches no database and no network. A link carries a spending secret, so no
//! error reported from here ever includes any part of the input.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use ffi_helpers::panic::catch_panic;
use secrecy::zeroize::Zeroize;
use zcash_protocol::consensus::{MAIN_NETWORK, NetworkType, TEST_NETWORK};

use crate::liberated_payment::{LiberatedPayment, Origin};
use crate::{NETWORK_ID_MAINNET, NETWORK_ID_TESTNET, unwrap_exc_or_null};

/// The encoding a gift card link was read from.
///
/// cbindgen:prefix-with-name
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GiftCardOrigin {
    /// A `v=1` link: `https://<host>#v=1&key=…&height=…`.
    V1,
    /// A legacy `v1=` JSON payload at `/payment-links/open#v1=`.
    LegacyV1,
    /// A legacy `v2=` JSON payload at `/payment-links/open#v2=`.
    LegacyV2,
    /// A legacy `v3=` JSON payload at `/payment-links/open#v3=`.
    LegacyV3,
}

impl From<Origin> for GiftCardOrigin {
    fn from(origin: Origin) -> Self {
        match origin {
            Origin::V1 => GiftCardOrigin::V1,
            Origin::LegacyV1 => GiftCardOrigin::LegacyV1,
            Origin::LegacyV2 => GiftCardOrigin::LegacyV2,
            Origin::LegacyV3 => GiftCardOrigin::LegacyV3,
        }
    }
}

/// A gift card read from a link.
///
/// Obtain via [`zcashlc_parse_gift_card_link`] and free with [`zcashlc_free_gift_card`], which
/// also zeroes the seed.
///
/// # Safety
///
/// - `funding_address` is a non-null, null-terminated UTF-8 string.
/// - `description` is null when the link has no description, and otherwise a non-null,
///   null-terminated UTF-8 string.
#[repr(C)]
pub struct GiftCardLink {
    /// The encoding the link was read from.
    origin: GiftCardOrigin,
    /// The network the card is on, as a network id (`0` testnet, `1` mainnet).
    network_id: u32,
    /// The height from which to scan for the card's funds.
    birthday_height: u32,
    /// Whether the link states an amount.
    has_amount: bool,
    /// The amount, in zatoshis, that the link claims the card holds. Zero when `has_amount` is
    /// false. Informational only: the funds found on chain are authoritative.
    amount: u64,
    /// The link's description, or null.
    description: *mut c_char,
    /// The Orchard-only default address of the card wallet, which the card is funded at.
    funding_address: *mut c_char,
    /// The 64-byte BIP 39 seed of the card wallet (ZIP 32 account 0, empty passphrase).
    seed: [u8; 64],
}

/// Reads a gift card link of any supported kind.
///
/// Returns null on failure, in which case the error is available via
/// `zcashlc_last_error_message`. Error messages never include any part of the link. Regtest
/// cards are refused because the SDK does not support that network.
///
/// # Safety
///
/// - `link` must be non-null and must point to a null-terminated UTF-8 string.
/// - The memory referenced by `link` must not be mutated for the duration of the function call.
/// - Call [`zcashlc_free_gift_card`] to free the returned pointer, which zeroes the seed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_parse_gift_card_link(link: *const c_char) -> *mut GiftCardLink {
    let res = catch_panic(|| {
        let link = unsafe { CStr::from_ptr(link) }
            .to_str()
            .map_err(|_| anyhow::anyhow!("gift card link is not valid UTF-8"))?;
        let card = LiberatedPayment::parse(link).map_err(|e| anyhow::anyhow!("{e}"))?;

        let (network_id, funding_address) = match card.network() {
            NetworkType::Main => (NETWORK_ID_MAINNET, card.funding_address(&MAIN_NETWORK)),
            NetworkType::Test => (NETWORK_ID_TESTNET, card.funding_address(&TEST_NETWORK)),
            NetworkType::Regtest => {
                return Err(anyhow::anyhow!(
                    "gift card link is for an unsupported network"
                ));
            }
        };
        let funding_address = funding_address.map_err(|e| anyhow::anyhow!("{e}"))?;
        let seed = card.seed().map_err(|e| anyhow::anyhow!("{e}"))?;

        // A percent-decoded description may contain NUL, which a C string cannot carry; it is
        // informational, so the NULs are dropped rather than refusing an otherwise valid card.
        let description = card
            .description()
            .map(|text| CString::new(text.replace('\0', "")))
            .transpose()?
            .map_or(std::ptr::null_mut(), CString::into_raw);
        let amount = card.amount();

        Ok(Box::into_raw(Box::new(GiftCardLink {
            origin: card.origin().into(),
            network_id,
            birthday_height: card.birthday_height(),
            has_amount: amount.is_some(),
            amount: amount.map_or(0, |a| a.into_u64()),
            description,
            funding_address: CString::new(funding_address)?.into_raw(),
            seed,
        })))
    });
    unwrap_exc_or_null(res)
}

/// Frees a [`GiftCardLink`] returned by [`zcashlc_parse_gift_card_link`], zeroing its seed.
///
/// # Safety
///
/// - `ptr` must be null or a pointer returned by [`zcashlc_parse_gift_card_link`] that has not
///   already been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_free_gift_card(ptr: *mut GiftCardLink) {
    if ptr.is_null() {
        return;
    }
    let mut card = unsafe { Box::from_raw(ptr) };
    card.seed.zeroize();
    if !card.description.is_null() {
        drop(unsafe { CString::from_raw(card.description) });
    }
    if !card.funding_address.is_null() {
        drop(unsafe { CString::from_raw(card.funding_address) });
    }
}

#[cfg(test)]
mod tests {
    use bip0039::{English, Mnemonic};

    use super::*;

    const HOST: &str = "https://gift.zodl.com/";

    // A published, never-funded reference vector of the legacy `v3` encoding (32 zero bytes of
    // entropy), as in `liberated_payment.rs`.
    const LEGACY_V3: &str = "https://legacy.example/payment-links/open#v3=WyJtYWluIiwiQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQSIsMzQ4MzE0MSwiMTAwMDAwMCIsImtuaWdodE1hZ2ljIiwxMS4xNzQ3LCJJdCdzIGEgZ3JlYXQgZGF5IHRvIHNoaWVsZCB5b3VyIFpFQyDwn5uh77iPIl0";

    fn parse(link: &str) -> *mut GiftCardLink {
        let link = CString::new(link).unwrap();
        unsafe { zcashlc_parse_gift_card_link(link.as_ptr()) }
    }

    fn string(ptr: *mut c_char) -> Option<String> {
        (!ptr.is_null()).then(|| unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_owned())
    }

    #[test]
    fn parses_the_legacy_v3_vector() {
        let ptr = parse(LEGACY_V3);
        assert!(!ptr.is_null());
        let card = unsafe { &*ptr };
        assert_eq!(card.origin, GiftCardOrigin::LegacyV3);
        assert_eq!(card.network_id, NETWORK_ID_MAINNET);
        assert_eq!(card.birthday_height, 3_483_141);
        assert!(card.has_amount);
        assert_eq!(card.amount, 1_000_000);
        assert_eq!(
            string(card.description).as_deref(),
            Some("It's a great day to shield your ZEC 🛡️")
        );
        let phrase = format!("{} art", ["abandon"; 23].join(" "));
        let expected = Mnemonic::<English>::from_phrase(phrase.as_str())
            .unwrap()
            .to_seed("");
        assert_eq!(card.seed, expected);
        let address = string(card.funding_address).unwrap();
        assert!(address.starts_with("u1"));
        assert_eq!(
            address,
            LiberatedPayment::parse(LEGACY_V3)
                .unwrap()
                .funding_address(&MAIN_NETWORK)
                .unwrap()
        );
        unsafe { zcashlc_free_gift_card(ptr) };
    }

    #[test]
    fn parses_a_v1_testnet_link() {
        let card =
            LiberatedPayment::new(NetworkType::Test, [9; 32], 3_000_000, None, None).unwrap();
        let ptr = parse(&card.to_link(HOST).unwrap());
        assert!(!ptr.is_null());
        let parsed = unsafe { &*ptr };
        assert_eq!(parsed.origin, GiftCardOrigin::V1);
        assert_eq!(parsed.network_id, NETWORK_ID_TESTNET);
        assert_eq!(parsed.birthday_height, 3_000_000);
        assert!(!parsed.has_amount);
        assert_eq!(parsed.amount, 0);
        assert!(parsed.description.is_null());
        assert_eq!(parsed.seed, card.seed().unwrap());
        assert!(
            string(parsed.funding_address)
                .unwrap()
                .starts_with("utest1")
        );
        unsafe { zcashlc_free_gift_card(ptr) };
    }

    #[test]
    fn refuses_bad_links_without_echoing_them() {
        let regtest = LiberatedPayment::new(NetworkType::Regtest, [9; 32], 1, None, None)
            .unwrap()
            .to_link(HOST)
            .unwrap();
        let mainnet = LiberatedPayment::new(NetworkType::Main, [9; 32], 1, None, None)
            .unwrap()
            .to_link(HOST)
            .unwrap();
        let key = mainnet
            .split('&')
            .find_map(|pair| pair.strip_prefix("key="))
            .unwrap()
            .to_owned();
        for link in [
            regtest,
            "https://example.com/#v=1".to_owned(),
            // The host is not part of the link, but it must be an `https` URL.
            format!("http://gift.zodl.com/#v=1&key={key}&height=1"),
            format!("https://gift.zodl.com/#v=1&key={key}x&height=1"),
            format!("https://gift.zodl.com/#v=1&key={key}"),
        ] {
            assert!(parse(&link).is_null(), "{link}");
            let message = ffi_helpers::error_handling::take_last_error()
                .map(|e| format!("{e:#}"))
                .unwrap_or_default();
            assert!(!message.is_empty());
            assert!(!message.contains(&key[6..]), "{message}");
        }
        unsafe { zcashlc_free_gift_card(std::ptr::null_mut()) };
    }
}
