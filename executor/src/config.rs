//! Operator configuration.
//!
//! Everything that decides *whether* a trade is worth doing lives on-chain, in
//! the market registry the contract enforces. What is here is the part the
//! contract cannot know: which RPC to watch, how big a clip to try, and which
//! Kuru books to route through today.

use std::path::Path;

use alloy::primitives::{Address, U256};
use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    pub rpc_url: String,
    /// Deployed `BasisTrader`.
    pub trader: Address,
    /// Perpl exchange, read for mark prices and book touch.
    pub perpl_exchange: Address,
    #[serde(default = "default_poll_ms")]
    pub poll_interval_ms: u64,
    /// Simulate and log, never broadcast. The safe default.
    #[serde(default = "default_true")]
    pub dry_run: bool,
    /// AUSD per unit of the cash token, in ppm. Passed to the contract on every
    /// call and bounded there by the market's own band.
    ///
    /// Static because Kuru has no working AUSD/USDC book to read it from - all
    /// three are either disabled or empty. Revisit if one comes back.
    #[serde(default = "default_peg")]
    pub cash_peg_ppm: u32,
    pub markets: Vec<MarketConfig>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct MarketConfig {
    /// Human label for logs.
    pub name: String,
    pub perp_id: u64,
    /// Kuru orderbooks to walk, entry direction.
    pub route: Vec<Address>,
    /// `isBuy` per hop for the entry (cash -> asset) direction. The exit
    /// reverses both the order of the hops and each flag.
    pub is_buy: Vec<bool>,
    #[serde(default)]
    pub native_send: Vec<bool>,
    /// Cash committed per entry, in the cash token's own units.
    pub clip_cash: U256,
    /// Margin posted per entry, AUSD 6dp.
    pub clip_margin_ausd: U256,
    /// How far through the book the perp leg may reach, in bps off the touch.
    ///
    /// Relative rather than a tick count: Perpl's price decimals run from 1 on
    /// BTC to 6 on MON, so the same number of ticks is $0.10 on one market and
    /// a millionth of a cent on another. Too tight and the fill-or-kill never
    /// fills; too loose and the edge gate rejects what it does fill.
    #[serde(default = "default_limit_offset_bps")]
    pub perp_limit_offset_bps: u64,
    /// Slippage allowance on the spot leg, bps off the perp mark.
    #[serde(default = "default_slippage_bps")]
    pub max_slippage_bps: u64,
    /// How far the realised lot count may sit from the expected one, bps.
    #[serde(default = "default_lot_band_bps")]
    pub lot_band_bps: u64,
    #[serde(default = "default_max_matches")]
    pub max_matches: u64,
    /// Ceiling on the short this market may carry, in lots. The contract has no
    /// opinion on how much risk the book should hold - it only polices each
    /// trade - so the inventory limit lives here, and without it a standing
    /// dislocation gets entered over and over until the capital runs out.
    pub max_position_lots: U256,
    /// Decimals of the spot token, used to turn a price into a lot count.
    pub spot_decimals: u8,
}

fn default_poll_ms() -> u64 { 2_000 }
fn default_true() -> bool { true }
fn default_peg() -> u32 { 999_600 }
fn default_slippage_bps() -> u64 { 50 }
fn default_lot_band_bps() -> u64 { 500 }
fn default_max_matches() -> u64 { 100 }
fn default_limit_offset_bps() -> u64 { 30 }

impl Config {
    pub fn load(path: &Path) -> anyhow::Result<Self> {
        let text = std::fs::read_to_string(path)
            .map_err(|e| anyhow::anyhow!("reading {}: {e}", path.display()))?;
        let config: Config = toml::from_str(&text)?;
        config.validate()?;
        Ok(config)
    }

    fn validate(&self) -> anyhow::Result<()> {
        for market in &self.markets {
            if market.route.is_empty() {
                anyhow::bail!("{}: route is empty", market.name);
            }
            if market.route.len() != market.is_buy.len() {
                anyhow::bail!("{}: route and is_buy differ in length", market.name);
            }
            if !market.native_send.is_empty() && market.native_send.len() != market.route.len() {
                anyhow::bail!("{}: native_send must be empty or match the route", market.name);
            }
        }
        Ok(())
    }
}

impl MarketConfig {
    /// `native_send` defaulted to all-false when the operator left it out.
    pub fn native_send_flags(&self) -> Vec<bool> {
        if self.native_send.is_empty() {
            vec![false; self.route.len()]
        } else {
            self.native_send.clone()
        }
    }

    /// The exit walks the same books the other way: hops in reverse order, each
    /// side flipped.
    pub fn exit_route(&self) -> (Vec<Address>, Vec<bool>, Vec<bool>) {
        let mut route = self.route.clone();
        let mut is_buy: Vec<bool> = self.is_buy.iter().map(|b| !b).collect();
        let mut native = self.native_send_flags();
        route.reverse();
        is_buy.reverse();
        native.reverse();
        (route, is_buy, native)
    }
}

#[cfg(test)]
mod tests {
    use alloy::primitives::address;

    use super::*;

    fn market(route: Vec<Address>, is_buy: Vec<bool>, native_send: Vec<bool>) -> MarketConfig {
        MarketConfig {
            name: "T".into(),
            perp_id: 1,
            route,
            is_buy,
            native_send,
            clip_cash: U256::from(1u64),
            clip_margin_ausd: U256::from(1u64),
            perp_limit_offset_bps: 30,
            max_slippage_bps: 50,
            lot_band_bps: 500,
            max_matches: 100,
            max_position_lots: U256::from(1u64),
            spot_decimals: 8,
        }
    }

    const A: Address = address!("0x0000000000000000000000000000000000000001");
    const B: Address = address!("0x0000000000000000000000000000000000000002");

    /// Unwinding walks the same books backwards, and each hop takes the other
    /// side. Getting only one of the two reversals right still type-checks and
    /// still submits - it just trades the wrong direction on every hop.
    #[test]
    fn exit_route_reverses_order_and_sides() {
        let m = market(vec![A, B], vec![false, true], vec![]);
        let (route, is_buy, native) = m.exit_route();

        assert_eq!(route, vec![B, A]);
        assert_eq!(is_buy, vec![false, true]);
        assert_eq!(native, vec![false, false]);
    }

    #[test]
    fn exit_route_reverses_native_flags_with_the_hops() {
        let m = market(vec![A, B], vec![true, true], vec![true, false]);
        let (_, _, native) = m.exit_route();
        assert_eq!(native, vec![false, true]);
    }

    #[test]
    fn native_send_defaults_to_all_erc20() {
        let m = market(vec![A, B], vec![true, true], vec![]);
        assert_eq!(m.native_send_flags(), vec![false, false]);
    }

    fn config_with(markets: Vec<MarketConfig>) -> Config {
        Config {
            rpc_url: "http://localhost".into(),
            trader: A,
            perpl_exchange: B,
            poll_interval_ms: 1,
            dry_run: true,
            cash_peg_ppm: 1_000_000,
            markets,
        }
    }

    #[test]
    fn validate_rejects_empty_route() {
        let config = config_with(vec![market(vec![], vec![], vec![])]);
        assert!(config.validate().is_err());
    }

    #[test]
    fn validate_rejects_mismatched_sides() {
        let config = config_with(vec![market(vec![A, B], vec![true], vec![])]);
        assert!(config.validate().is_err());
    }

    #[test]
    fn validate_rejects_mismatched_native_flags() {
        let config = config_with(vec![market(vec![A, B], vec![true, true], vec![true])]);
        assert!(config.validate().is_err());
    }

    #[test]
    fn validate_accepts_a_well_formed_market() {
        let config = config_with(vec![market(vec![A, B], vec![true, false], vec![])]);
        assert!(config.validate().is_ok());
    }
}
