//! Turning a market configuration and the current book into a concrete call.
//!
//! None of this decides whether the trade is good - that is the contract's job
//! and it re-derives it from the actual fills. What happens here is only the
//! shaping: how much to commit, which price the fill-or-kill may reach to, and
//! the guard rails the contract then checks the realised fill against.

use alloy::primitives::U256;

use crate::{
    bindings::{
        BasisTrader::{EnterParams, ExitParams},
        IPerplRead,
    },
    config::MarketConfig,
    quote::apply_slippage_floor,
};

/// Everything read off the exchange for one perpetual at one block.
#[derive(Debug, Clone)]
pub struct PerpSnapshot {
    pub mark_pns: U256,
    pub best_bid_pns: U256,
    pub best_ask_pns: U256,
    pub price_decimals: u32,
    pub lot_decimals: u32,
    pub taker_fee_ppm: u64,
}

impl PerpSnapshot {
    pub fn from_info(info: &IPerplRead::PerpetualInfoV2, taker_fee_ppm: u64) -> Self {
        Self {
            mark_pns: info.markPNS,
            best_bid_pns: info.maxBidPriceONS,
            best_ask_pns: info.minAskPriceONS,
            price_decimals: info.priceDecimals.to::<u32>(),
            lot_decimals: info.lotDecimals.to::<u32>(),
            taker_fee_ppm,
        }
    }

    /// Spot units one unit of cash buys at the mark, used only to set the
    /// slippage floor - the real price comes from the fill.
    fn expected_asset_out(&self, cash: U256, spot_decimals: u8) -> U256 {
        if self.mark_pns.is_zero() {
            return U256::ZERO;
        }
        // cash (6dp) / (markPNS / 10^priceDecimals) scaled into spot decimals.
        let price_scale = U256::from(10u64).pow(U256::from(self.price_decimals));
        let spot_scale = U256::from(10u64).pow(U256::from(spot_decimals as u64));
        let cash_scale = U256::from(1_000_000u64); // cash tokens here are 6dp stables
        cash * price_scale * spot_scale / (self.mark_pns * cash_scale)
    }
}

pub fn build_enter(
    market: &MarketConfig,
    snapshot: &PerpSnapshot,
    cash_peg_ppm: u32,
    request_id: u64,
) -> EnterParams {
    let expected_asset = snapshot.expected_asset_out(market.clip_cash, market.spot_decimals);
    let min_asset_out = apply_slippage_floor(expected_asset, market.max_slippage_bps);

    let expected_lots = to_lots(expected_asset, market.spot_decimals, snapshot.lot_decimals);
    let (min_lots, max_lots) = band(expected_lots, market.lot_band_bps);

    // Reach *down* through the bids: a short sells, so a lower limit crosses
    // more of the book.
    let limit = snapshot
        .best_bid_pns
        .saturating_sub(offset_ticks(snapshot.best_bid_pns, market.perp_limit_offset_bps));

    EnterParams {
        perpId: U256::from(market.perp_id),
        cashIn: market.clip_cash,
        cashPegPpm: cash_peg_ppm,
        route: market.route.clone(),
        isBuy: market.is_buy.clone(),
        nativeSend: market.native_send_flags(),
        minAssetOut: min_asset_out,
        perplLimitPricePNS: limit,
        minLotLNS: min_lots,
        maxLotLNS: max_lots,
        marginCNS: market.clip_margin_ausd,
        maxMatches: U256::from(market.max_matches),
        requestId: U256::from(request_id),
    }
}

pub fn build_exit(
    market: &MarketConfig,
    snapshot: &PerpSnapshot,
    asset_in: U256,
    cash_peg_ppm: u32,
    request_id: u64,
) -> ExitParams {
    let (route, is_buy, native_send) = market.exit_route();

    let price_scale = U256::from(10u64).pow(U256::from(snapshot.price_decimals));
    let spot_scale = U256::from(10u64).pow(U256::from(market.spot_decimals as u64));
    let expected_cash =
        asset_in * snapshot.mark_pns * U256::from(1_000_000u64) / (price_scale * spot_scale);
    let min_cash_out = apply_slippage_floor(expected_cash, market.max_slippage_bps);

    // Reach *up* through the asks to buy the short back.
    let limit =
        snapshot.best_ask_pns + offset_ticks(snapshot.best_ask_pns, market.perp_limit_offset_bps);

    ExitParams {
        perpId: U256::from(market.perp_id),
        assetIn: asset_in,
        cashPegPpm: cash_peg_ppm,
        route,
        isBuy: is_buy,
        nativeSend: native_send,
        minCashOut: min_cash_out,
        perplLimitPricePNS: limit,
        maxMatches: U256::from(market.max_matches),
        requestId: U256::from(request_id),
    }
}

/// Price ticks `bps` away from `price`, never zero - a zero offset would make
/// the taker order rest at the touch and fill nothing.
fn offset_ticks(price: U256, bps: u64) -> U256 {
    let ticks = price * U256::from(bps) / U256::from(10_000u64);
    ticks.max(U256::from(1u64))
}

fn to_lots(amount: U256, token_decimals: u8, lot_decimals: u32) -> U256 {
    let token_decimals = token_decimals as u32;
    if token_decimals >= lot_decimals {
        amount / U256::from(10u64).pow(U256::from(token_decimals - lot_decimals))
    } else {
        amount * U256::from(10u64).pow(U256::from(lot_decimals - token_decimals))
    }
}

/// A band around the expected lot count, so a book that moved between the
/// simulation and inclusion is caught by the contract rather than silently
/// hedging the wrong size.
fn band(expected: U256, bps: u64) -> (U256, U256) {
    let width = U256::from(bps);
    let scale = U256::from(10_000u64);
    let low = expected * (scale - width) / scale;
    let high = expected * (scale + width) / scale;
    (low, high.max(expected + U256::from(1u64)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::quote::apply_slippage_floor;

    #[test]
    fn lots_round_down_so_the_hedge_never_exceeds_the_spot() {
        // cbBTC is 8 decimals against the BTC perp's 5 lot decimals, so a lot
        // is 1e3 token units and anything under one is dust.
        assert_eq!(to_lots(U256::from(348_027u64), 8, 5), U256::from(348u64));
        assert_eq!(to_lots(U256::from(999u64), 8, 5), U256::ZERO);
    }

    #[test]
    fn lots_scale_up_when_the_perp_is_finer_than_the_token() {
        // MON's perp has 0 lot decimals against an 18-decimal token, but the
        // inverse direction has to work for any market that lists the other way.
        assert_eq!(to_lots(U256::from(5u64), 2, 4), U256::from(500u64));
    }

    /// The limit must always move off the touch. A zero offset leaves the taker
    /// order resting at the touch, where it fills nothing and the fill-or-kill
    /// reverts - which looks like a dead market rather than a misconfiguration.
    #[test]
    fn offset_is_never_zero_even_on_a_tiny_price() {
        assert_eq!(offset_ticks(U256::from(10u64), 30), U256::from(1u64));
        assert_eq!(offset_ticks(U256::ZERO, 30), U256::from(1u64));
    }

    #[test]
    fn offset_is_relative_to_price() {
        // 30bps of 863,672 PNS, BTC's touch at one price decimal.
        assert_eq!(offset_ticks(U256::from(863_672u64), 30), U256::from(2591u64));
    }

    #[test]
    fn band_brackets_the_expected_lots() {
        let (low, high) = band(U256::from(1000u64), 500);
        assert_eq!(low, U256::from(950u64));
        assert_eq!(high, U256::from(1050u64));
    }

    /// A band that collapsed to a point would reject every fill, since the
    /// realised lot count is derived from a spot fill that is never exact.
    #[test]
    fn band_stays_open_on_small_numbers() {
        let (low, high) = band(U256::from(1u64), 500);
        assert!(high > low, "band must admit at least one value");
        assert!(high >= U256::from(2u64));
    }

    #[test]
    fn slippage_floor_cuts_the_expected_amount() {
        assert_eq!(apply_slippage_floor(U256::from(10_000u64), 50), U256::from(9950u64));
        assert_eq!(apply_slippage_floor(U256::from(10_000u64), 0), U256::from(10_000u64));
    }

    /// A slippage allowance above 100% must floor at zero rather than wrap.
    #[test]
    fn slippage_floor_saturates() {
        assert_eq!(apply_slippage_floor(U256::from(10_000u64), 20_000), U256::ZERO);
    }
}
