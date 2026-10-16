//! Proof-of-work target block spacing and the conversions between block counts and target time.
//!
//! The consensus rules aim for 150 s between blocks before Blossom, 75 s from Blossom (ZIP 208),
//! and 25 s from NU7. A span converted with one constant is wrong as soon as it crosses one of
//! those activations, so every such conversion in this crate goes through here. Everything is
//! generic over [`Parameters`], so a registered custom network uses its own activation heights.
//!
//! This is an interim copy that mirrors the upstream ZIP 218 proposal for librustzcash.
//! `pow_target_spacing` and `default_tx_expiry_delta` keep the names proposed there (here
//! `pow_target_spacing` returns seconds as a `u32` where upstream returns a `Duration`), and
//! `target_seconds_between` is a signed-seconds counterpart of upstream's `target_time_between`.
//! Replace the copy with the upstream helpers once a release ships them.

use zcash_primitives::transaction::builder::DEFAULT_TX_EXPIRY_DELTA;
use zcash_protocol::consensus::{BlockHeight, H0, NetworkUpgrade, Parameters};

const PRE_BLOSSOM_POW_TARGET_SPACING: u32 = 150;
const POST_BLOSSOM_POW_TARGET_SPACING: u32 = 75;
const POST_NU7_POW_TARGET_SPACING: u32 = 25;

/// The default expiry delta, in blocks, once NU7 is active at the target height: the 50 minutes
/// librustzcash's 40-block default spans at 75 seconds, at NU7's 25.
const POST_NU7_DEFAULT_TX_EXPIRY_DELTA: u32 = 120;

/// The target spacing of the block at `height`, in seconds: the time the consensus rules aim to
/// put between the blocks at `height - 1` and `height`.
pub(crate) fn pow_target_spacing<P: Parameters>(params: &P, height: BlockHeight) -> u32 {
    if !params.is_nu_active(NetworkUpgrade::Blossom, height) {
        PRE_BLOSSOM_POW_TARGET_SPACING
    } else if !params.is_nu_active(NetworkUpgrade::Nu7, height) {
        POST_BLOSSOM_POW_TARGET_SPACING
    } else {
        POST_NU7_POW_TARGET_SPACING
    }
}

/// A maximal run of heights whose blocks share one target spacing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct SpacingEra {
    /// The first height of the era.
    pub(crate) start: BlockHeight,
    /// The first height after the era, or `None` when no later upgrade changes the spacing.
    pub(crate) end: Option<BlockHeight>,
    /// The target spacing of every block in the era, in seconds.
    pub(crate) spacing: u32,
}

/// The heights at which the spacing changes, ascending: the activation heights of the upgrades
/// that can change it, wherever the spacing there differs from the block before.
fn spacing_changes<P: Parameters>(params: &P) -> Vec<BlockHeight> {
    let mut changes: Vec<BlockHeight> = [NetworkUpgrade::Blossom, NetworkUpgrade::Nu7]
        .into_iter()
        .filter_map(|upgrade| params.activation_height(upgrade))
        .filter(|&height| {
            height > H0
                && pow_target_spacing(params, height) != pow_target_spacing(params, height - 1)
        })
        .collect();
    changes.sort();
    changes.dedup();
    changes
}

/// The spacing era that contains `height`.
pub(crate) fn spacing_era<P: Parameters>(params: &P, height: BlockHeight) -> SpacingEra {
    let changes = spacing_changes(params);
    SpacingEra {
        start: changes
            .iter()
            .rev()
            .copied()
            .find(|&change| change <= height)
            .unwrap_or(H0),
        end: changes.iter().copied().find(|&change| change > height),
        spacing: pow_target_spacing(params, height),
    }
}

/// The target time of the blocks after `from` up to and including `to`, in seconds. Negative when
/// `to` is below `from`. The sum over every height fits an `i64` with room to spare.
pub(crate) fn target_seconds_between<P: Parameters>(
    params: &P,
    from: BlockHeight,
    to: BlockHeight,
) -> i64 {
    if to < from {
        return -target_seconds_between(params, to, from);
    }
    let mut seconds = 0i64;
    let mut height = from;
    while height < to {
        let era = spacing_era(params, height + 1);
        // The last height of this era that is still within `to`.
        let segment_end = match era.end {
            Some(end) if end <= to => end - 1,
            _ => to,
        };
        seconds += i64::from(segment_end - height) * i64::from(era.spacing);
        height = segment_end;
    }
    seconds
}

/// The height `seconds` of target time reach from `from`, counting whole blocks only. For
/// `seconds >= 0`, the highest height whose blocks after `from` take no more than `seconds`. For a
/// negative `seconds`, the lowest height whose blocks up to `from` take no more than its
/// magnitude, never below 0.
pub(crate) fn height_after_target_seconds<P: Parameters>(
    params: &P,
    from: BlockHeight,
    seconds: i64,
) -> BlockHeight {
    let max_height = BlockHeight::from_u32(u32::MAX);
    let mut height = from;
    if seconds >= 0 {
        let mut remaining = seconds;
        while height < max_height {
            let era = spacing_era(params, height + 1);
            // The blocks after `height` that are still in this era.
            let in_era = match era.end {
                Some(end) => end - height - 1,
                None => max_height - height,
            };
            let spacing = i64::from(era.spacing);
            let affordable = remaining / spacing;
            if affordable < i64::from(in_era) {
                return height + u32::try_from(affordable).expect("below a u32 block count");
            }
            remaining -= i64::from(in_era) * spacing;
            height = height + in_era;
        }
    } else {
        let mut remaining = seconds.checked_neg().unwrap_or(i64::MAX);
        while height > H0 {
            let era = spacing_era(params, height);
            // Stepping back uncounts this era's blocks down to its first, but never the genesis
            // block, which has no block before it.
            let in_era = height - era.start.max(BlockHeight::from_u32(1)) + 1;
            let spacing = i64::from(era.spacing);
            let affordable = remaining / spacing;
            if affordable < i64::from(in_era) {
                return height - u32::try_from(affordable).expect("below a u32 block count");
            }
            remaining -= i64::from(in_era) * spacing;
            height = height - in_era;
        }
    }
    height
}

/// The default expiry delta, in blocks, of a transaction whose target height is `target_height`:
/// 40 before NU7, and 120 from NU7, the same 50 minutes.
pub(crate) fn default_tx_expiry_delta<P: Parameters>(
    params: &P,
    target_height: BlockHeight,
) -> u32 {
    if params.is_nu_active(NetworkUpgrade::Nu7, target_height) {
        POST_NU7_DEFAULT_TX_EXPIRY_DELTA
    } else {
        DEFAULT_TX_EXPIRY_DELTA
    }
}

/// The target height of a transaction with the default expiry delta that expires at
/// `expiry_height`: the candidate whose default expiry is exactly that height. No target produces
/// an expiry in the 80 heights from 40 blocks after NU7 activation; those get the earlier
/// candidate, so a derived height is never later than the real target height.
pub(crate) fn default_tx_target_height_for_expiry<P: Parameters>(
    params: &P,
    expiry_height: BlockHeight,
) -> BlockHeight {
    let post_nu7_target = expiry_height - POST_NU7_DEFAULT_TX_EXPIRY_DELTA;
    let pre_nu7_target = expiry_height - DEFAULT_TX_EXPIRY_DELTA;
    [post_nu7_target, pre_nu7_target]
        .into_iter()
        .find(|&target| target + default_tx_expiry_delta(params, target) == expiry_height)
        .unwrap_or(post_nu7_target)
}

#[cfg(test)]
mod tests {
    use super::*;
    use zcash_protocol::consensus::{MAIN_NETWORK, TEST_NETWORK};
    use zcash_protocol::local_consensus::LocalNetwork;

    const TESTNET_BLOSSOM: u32 = 584_000;
    const TESTNET_NU7: u32 = 4_465_026;
    const MAINNET_BLOSSOM: u32 = 653_600;
    /// A mainnet height long behind the chain tip. The pinned crate gives mainnet no NU7 height,
    /// and a later one will put it well above this, so every assertion on `MAIN_NETWORK` stays at
    /// or below this height. Where a test needs mainnet's schedule beyond it, with NU7 never
    /// activating, it uses `mainnet_without_nu7`.
    const MAINNET_SETTLED: u32 = 3_000_000;

    fn h(height: u32) -> BlockHeight {
        BlockHeight::from_u32(height)
    }

    /// Every other upgrade at height 1; Blossom and NU7 where given.
    fn custom(blossom: Option<u32>, nu7: Option<u32>) -> LocalNetwork {
        let one = Some(h(1));
        LocalNetwork {
            overwinter: one,
            sapling: one,
            blossom: blossom.map(h),
            heartwood: one,
            canopy: one,
            nu5: one,
            nu6: one,
            nu6_1: one,
            nu6_2: one,
            nu6_3: one,
            nu7: nu7.map(h),
        }
    }

    /// Mainnet's schedule for as long as NU7 has no activation height there: Blossom at its mainnet
    /// height, NU7 never. It stands in for `MAIN_NETWORK` in every assertion that no NU7 era ever
    /// begins, which `MAIN_NETWORK` itself would stop satisfying once the crate gives it an NU7
    /// height.
    fn mainnet_without_nu7() -> LocalNetwork {
        custom(Some(MAINNET_BLOSSOM), None)
    }

    fn era(start: u32, end: Option<u32>, spacing: u32) -> SpacingEra {
        SpacingEra {
            start: h(start),
            end: end.map(h),
            spacing,
        }
    }

    /// Both standard networks, NU7 above Blossom, both at one height, NU7 without Blossom, Blossom
    /// at genesis, and mainnet's Blossom height with NU7 never activating. The checks run through
    /// it are properties of any schedule, never fixed values, so listing `MAIN_NETWORK` pins
    /// nothing about its NU7 height.
    macro_rules! for_every_network {
        ($check:ident) => {
            $check(&MAIN_NETWORK);
            $check(&TEST_NETWORK);
            $check(&custom(Some(1), Some(300)));
            $check(&custom(Some(1), Some(1)));
            $check(&custom(None, Some(10)));
            $check(&custom(Some(0), None));
            $check(&mainnet_without_nu7());
        };
    }

    /// Block-by-block addition: the definition `target_seconds_between` must match.
    fn summed_spacing<P: Parameters>(params: &P, from: u32, to: u32) -> i64 {
        if to < from {
            return -summed_spacing(params, to, from);
        }
        (from + 1..=to)
            .map(|height| i64::from(pow_target_spacing(params, h(height))))
            .sum()
    }

    fn heights_around_changes<P: Parameters>(params: &P) -> Vec<BlockHeight> {
        let mut heights = vec![0, 1, 2, 3, u32::MAX - 1, u32::MAX];
        for change in spacing_changes(params).into_iter().map(u32::from) {
            heights.extend(change.saturating_sub(3)..=change.saturating_add(3));
            heights.push(change.saturating_add(1_000));
        }
        heights.sort_unstable();
        heights.dedup();
        heights.into_iter().map(h).collect()
    }

    fn assert_eras_are_maximal<P: Parameters>(params: &P) {
        for height in heights_around_changes(params) {
            let era = spacing_era(params, height);
            assert!(era.start <= height);
            assert_eq!(era.spacing, pow_target_spacing(params, height));
            assert_eq!(pow_target_spacing(params, era.start), era.spacing);
            if era.start > H0 {
                assert_ne!(
                    pow_target_spacing(params, era.start - 1),
                    era.spacing,
                    "era of {height} starts late"
                );
            }
            if let Some(end) = era.end {
                assert!(end > height);
                assert_eq!(pow_target_spacing(params, end - 1), era.spacing);
                assert_ne!(
                    pow_target_spacing(params, end),
                    era.spacing,
                    "era of {height} ends early"
                );
            }
        }
    }

    fn assert_sums_each_block<P: Parameters>(params: &P) {
        let mut centers: Vec<u32> = spacing_changes(params).into_iter().map(u32::from).collect();
        centers.push(5);
        for center in centers {
            let low = center.saturating_sub(5);
            for from in low..=center + 5 {
                for to in low..=center + 5 {
                    assert_eq!(
                        target_seconds_between(params, h(from), h(to)),
                        summed_spacing(params, from, to),
                        "from {from} to {to}"
                    );
                }
            }
        }
    }

    fn assert_round_trips<P: Parameters>(params: &P) {
        let heights = heights_around_changes(params);
        for &from in &heights {
            for &to in &heights {
                let seconds = target_seconds_between(params, from, to);
                assert_eq!(
                    height_after_target_seconds(params, from, seconds),
                    to,
                    "from {from} to {to}"
                );
            }
        }
    }

    fn assert_whole_blocks_only<P: Parameters>(params: &P) {
        let offsets: [i64; 25] = [
            -1_000_000, -10_000, -151, -150, -149, -76, -75, -74, -26, -25, -24, -1, 0, 1, 24, 25,
            26, 74, 75, 76, 149, 150, 151, 10_000, 1_000_000,
        ];
        for &from in &heights_around_changes(params) {
            for seconds in offsets {
                let reached = height_after_target_seconds(params, from, seconds);
                if seconds >= 0 {
                    assert!(target_seconds_between(params, from, reached) <= seconds);
                    if reached < h(u32::MAX) {
                        assert!(
                            target_seconds_between(params, from, reached + 1) > seconds,
                            "from {from}, {seconds} s"
                        );
                    }
                } else {
                    assert!(target_seconds_between(params, reached, from) <= -seconds);
                    if reached > H0 {
                        assert!(
                            target_seconds_between(params, reached - 1, from) > -seconds,
                            "from {from}, {seconds} s"
                        );
                    }
                }
            }
        }
    }

    /// The walk forward stops at the highest height, whatever the spacing there is.
    fn assert_stops_at_the_top<P: Parameters>(params: &P) {
        assert_eq!(
            height_after_target_seconds(params, h(u32::MAX - 1), 1_000),
            h(u32::MAX)
        );
        assert_eq!(
            height_after_target_seconds(params, h(0), i64::MAX),
            h(u32::MAX)
        );
    }

    /// The inverse exactly as the design states it.
    fn stated_inverse<P: Parameters>(params: &P, expiry: BlockHeight) -> BlockHeight {
        let post = expiry - 120;
        if params.is_nu_active(NetworkUpgrade::Nu7, post) {
            return post;
        }
        let pre = expiry - 40;
        if !params.is_nu_active(NetworkUpgrade::Nu7, pre) {
            return pre;
        }
        post
    }

    fn assert_matches_stated_inverse<P: Parameters>(params: &P) {
        let mut expiries: Vec<u32> = (0..=300).collect();
        for change in spacing_changes(params).into_iter().map(u32::from) {
            expiries.extend(change.saturating_sub(200)..=change.saturating_add(200));
        }
        for expiry in expiries.into_iter().map(h) {
            assert_eq!(
                default_tx_target_height_for_expiry(params, expiry),
                stated_inverse(params, expiry),
                "expiry {expiry}"
            );
        }
    }

    #[test]
    fn spacing_follows_blossom_and_nu7() {
        assert_eq!(pow_target_spacing(&MAIN_NETWORK, h(0)), 150);
        assert_eq!(
            pow_target_spacing(&MAIN_NETWORK, h(MAINNET_BLOSSOM - 1)),
            150
        );
        assert_eq!(pow_target_spacing(&MAIN_NETWORK, h(MAINNET_BLOSSOM)), 75);
        assert_eq!(pow_target_spacing(&MAIN_NETWORK, h(MAINNET_SETTLED)), 75);
        assert_eq!(
            pow_target_spacing(&TEST_NETWORK, h(TESTNET_BLOSSOM - 1)),
            150
        );
        assert_eq!(pow_target_spacing(&TEST_NETWORK, h(TESTNET_BLOSSOM)), 75);
        assert_eq!(pow_target_spacing(&TEST_NETWORK, h(TESTNET_NU7 - 1)), 75);
        assert_eq!(pow_target_spacing(&TEST_NETWORK, h(TESTNET_NU7)), 25);
        assert_eq!(pow_target_spacing(&TEST_NETWORK, h(u32::MAX)), 25);
    }

    #[test]
    fn spacing_stays_at_75_seconds_where_nu7_never_activates() {
        let network = mainnet_without_nu7();
        assert_eq!(pow_target_spacing(&network, h(MAINNET_BLOSSOM - 1)), 150);
        assert_eq!(pow_target_spacing(&network, h(MAINNET_BLOSSOM)), 75);
        assert_eq!(pow_target_spacing(&network, h(MAINNET_SETTLED)), 75);
        assert_eq!(pow_target_spacing(&network, h(100_000_000)), 75);
        assert_eq!(pow_target_spacing(&network, h(u32::MAX)), 75);
    }

    #[test]
    fn eras_on_the_standard_networks() {
        assert_eq!(
            spacing_era(&TEST_NETWORK, h(0)),
            era(0, Some(TESTNET_BLOSSOM), 150)
        );
        assert_eq!(
            spacing_era(&TEST_NETWORK, h(TESTNET_BLOSSOM)),
            era(TESTNET_BLOSSOM, Some(TESTNET_NU7), 75)
        );
        assert_eq!(
            spacing_era(&TEST_NETWORK, h(TESTNET_NU7 - 1)),
            era(TESTNET_BLOSSOM, Some(TESTNET_NU7), 75)
        );
        assert_eq!(
            spacing_era(&TEST_NETWORK, h(TESTNET_NU7)),
            era(TESTNET_NU7, None, 25)
        );
        assert_eq!(
            spacing_era(&MAIN_NETWORK, h(MAINNET_BLOSSOM - 1)),
            era(0, Some(MAINNET_BLOSSOM), 150)
        );
        // Where mainnet's era ends depends on the NU7 height it is given, so only its start and
        // spacing are pinned, and that it ends beyond the settled height. The unbounded era is
        // asserted on the network without NU7.
        let mainnet_era = spacing_era(&MAIN_NETWORK, h(MAINNET_SETTLED));
        assert_eq!(mainnet_era.start, h(MAINNET_BLOSSOM));
        assert_eq!(mainnet_era.spacing, 75);
        assert!(mainnet_era.end.is_none_or(|end| end > h(MAINNET_SETTLED)));
        assert_eq!(
            spacing_era(&mainnet_without_nu7(), h(MAINNET_SETTLED)),
            era(MAINNET_BLOSSOM, None, 75)
        );
    }

    #[test]
    fn eras_on_custom_networks() {
        assert_eq!(
            spacing_era(&custom(None, Some(10)), h(1_000)),
            era(0, None, 150)
        );
        assert_eq!(spacing_era(&custom(Some(0), None), h(0)), era(0, None, 75));
        assert_eq!(
            spacing_era(&custom(Some(1), Some(1)), h(0)),
            era(0, Some(1), 150)
        );
        assert_eq!(
            spacing_era(&custom(Some(1), Some(1)), h(1)),
            era(1, None, 25)
        );
    }

    #[test]
    fn eras_are_maximal_runs_of_equal_spacing() {
        for_every_network!(assert_eras_are_maximal);
    }

    #[test]
    fn target_seconds_between_the_testnet_nu7_boundary() {
        assert_eq!(
            target_seconds_between(&TEST_NETWORK, h(TESTNET_NU7 - 1), h(TESTNET_NU7)),
            25
        );
        assert_eq!(
            target_seconds_between(&TEST_NETWORK, h(TESTNET_NU7 - 2), h(TESTNET_NU7)),
            100
        );
        assert_eq!(
            target_seconds_between(&TEST_NETWORK, h(TESTNET_NU7), h(TESTNET_NU7 - 2)),
            -100
        );
        assert_eq!(
            target_seconds_between(&TEST_NETWORK, h(TESTNET_NU7), h(TESTNET_NU7)),
            0
        );
    }

    /// Mainnet's heights with NU7 never activating: 653,599 blocks at 150 s and 4,294,313,696 at
    /// 75 s. Testnet: 583,999 at 150 s, 3,881,026 at 75 s and 4,290,502,270 at 25 s.
    #[test]
    fn target_seconds_between_spans_every_height_without_overflow() {
        let mainnet = mainnet_without_nu7();
        assert_eq!(
            target_seconds_between(&mainnet, h(0), h(u32::MAX)),
            322_171_567_050
        );
        assert_eq!(
            target_seconds_between(&mainnet, h(u32::MAX), h(0)),
            -322_171_567_050
        );
        assert_eq!(
            target_seconds_between(&TEST_NETWORK, h(0), h(u32::MAX)),
            107_641_233_550
        );
    }

    /// Mainnet up to a settled height: 653,599 blocks at 150 s and 2,346,401 at 75 s.
    #[test]
    fn target_seconds_between_on_mainnet_up_to_a_settled_height() {
        assert_eq!(
            target_seconds_between(&MAIN_NETWORK, h(0), h(MAINNET_SETTLED)),
            274_019_925
        );
    }

    #[test]
    fn target_seconds_between_sums_the_spacing_of_each_block() {
        for_every_network!(assert_sums_each_block);
    }

    #[test]
    fn height_after_target_seconds_counts_whole_blocks() {
        let from = h(TESTNET_NU7 - 2);
        assert_eq!(height_after_target_seconds(&TEST_NETWORK, from, 0), from);
        assert_eq!(height_after_target_seconds(&TEST_NETWORK, from, 74), from);
        assert_eq!(
            height_after_target_seconds(&TEST_NETWORK, from, 75),
            h(TESTNET_NU7 - 1)
        );
        assert_eq!(
            height_after_target_seconds(&TEST_NETWORK, from, 99),
            h(TESTNET_NU7 - 1)
        );
        assert_eq!(
            height_after_target_seconds(&TEST_NETWORK, from, 100),
            h(TESTNET_NU7)
        );
        assert_eq!(
            height_after_target_seconds(&TEST_NETWORK, from, 124),
            h(TESTNET_NU7)
        );
        assert_eq!(
            height_after_target_seconds(&TEST_NETWORK, from, 125),
            h(TESTNET_NU7 + 1)
        );
    }

    #[test]
    fn negative_target_seconds_walk_back() {
        let from = h(TESTNET_NU7 + 1);
        assert_eq!(height_after_target_seconds(&TEST_NETWORK, from, -24), from);
        assert_eq!(
            height_after_target_seconds(&TEST_NETWORK, from, -25),
            h(TESTNET_NU7)
        );
        assert_eq!(
            height_after_target_seconds(&TEST_NETWORK, from, -49),
            h(TESTNET_NU7)
        );
        assert_eq!(
            height_after_target_seconds(&TEST_NETWORK, from, -50),
            h(TESTNET_NU7 - 1)
        );
        assert_eq!(
            height_after_target_seconds(&TEST_NETWORK, from, -125),
            h(TESTNET_NU7 - 2)
        );
    }

    #[test]
    fn height_after_target_seconds_stops_at_the_ends_of_the_range() {
        assert_eq!(
            height_after_target_seconds(&MAIN_NETWORK, h(10), -1_000_000),
            h(0)
        );
        assert_eq!(
            height_after_target_seconds(&MAIN_NETWORK, h(10), i64::MIN),
            h(0)
        );
        for_every_network!(assert_stops_at_the_top);
    }

    #[test]
    fn height_after_target_seconds_inverts_target_seconds_between() {
        for_every_network!(assert_round_trips);
    }

    #[test]
    fn height_after_target_seconds_is_the_furthest_whole_block() {
        for_every_network!(assert_whole_blocks_only);
    }

    #[test]
    fn default_tx_expiry_delta_is_120_blocks_from_nu7() {
        assert_eq!(DEFAULT_TX_EXPIRY_DELTA, 40);
        assert_eq!(
            default_tx_expiry_delta(&TEST_NETWORK, h(TESTNET_NU7 - 1)),
            40
        );
        assert_eq!(default_tx_expiry_delta(&TEST_NETWORK, h(TESTNET_NU7)), 120);
        assert_eq!(
            default_tx_expiry_delta(&MAIN_NETWORK, h(MAINNET_SETTLED)),
            40
        );
        assert_eq!(
            default_tx_expiry_delta(&mainnet_without_nu7(), h(u32::MAX)),
            40
        );
    }

    #[test]
    fn the_expiry_inverse_recovers_every_default_target() {
        for target in (TESTNET_NU7 - 300..=TESTNET_NU7 + 300).map(h) {
            let expiry = target + default_tx_expiry_delta(&TEST_NETWORK, target);
            assert_eq!(
                default_tx_target_height_for_expiry(&TEST_NETWORK, expiry),
                target,
                "target {target}"
            );
        }
        for target in (MAINNET_SETTLED - 140..=MAINNET_SETTLED - 40).map(h) {
            assert_eq!(
                default_tx_target_height_for_expiry(&MAIN_NETWORK, target + 40),
                target
            );
        }
    }

    #[test]
    fn an_expiry_no_default_produces_answers_the_earlier_target() {
        for expiry in TESTNET_NU7 + 40..=TESTNET_NU7 + 119 {
            assert_eq!(
                default_tx_target_height_for_expiry(&TEST_NETWORK, h(expiry)),
                h(expiry - 120),
                "expiry {expiry}"
            );
        }
        assert_eq!(
            default_tx_target_height_for_expiry(&TEST_NETWORK, h(TESTNET_NU7 + 39)),
            h(TESTNET_NU7 - 1)
        );
        assert_eq!(
            default_tx_target_height_for_expiry(&TEST_NETWORK, h(TESTNET_NU7 + 120)),
            h(TESTNET_NU7)
        );
    }

    #[test]
    fn the_expiry_inverse_matches_its_stated_rule_including_saturation() {
        for_every_network!(assert_matches_stated_inverse);
        assert_matches_stated_inverse(&custom(Some(1), Some(0)));
        assert_eq!(
            default_tx_target_height_for_expiry(&MAIN_NETWORK, h(10)),
            h(0)
        );
    }
}
