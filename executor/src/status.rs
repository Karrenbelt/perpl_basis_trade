//! What the book is worth right now, in one number and the parts behind it.
//!
//! Equity is carried in AUSD because that is what the perp leg settles in and
//! what the edge gate measures against. Cash held in another stable is
//! converted at the configured peg - the same peg the contract is given and
//! bounds, so the reported number and the enforced one use one rate.

use std::collections::BTreeMap;

use alloy::{
    primitives::{Address, I256, U256},
    providers::Provider,
};
use anyhow::Result;

use crate::{
    bindings::{BasisTrader, IErc20},
    config::{Config, MarketConfig},
    units,
};

pub struct Holding {
    pub symbol: String,
    pub decimals: u8,
    pub amount: U256,
}

pub struct OpenPosition {
    pub name: String,
    pub lots: U256,
    pub lot_decimals: u8,
    pub entry_pns: U256,
    pub mark_pns: U256,
    pub price_decimals: u8,
    pub collateral_cns: U256,
    pub pnl_cns: I256,
}

pub struct Status {
    pub trader: Address,
    pub perpl_account_id: U256,
    pub wallet: Vec<Holding>,
    pub free_collateral_cns: U256,
    pub positions: Vec<OpenPosition>,
    /// Spot still held that no longer has a hedge against it, valued at mark.
    pub unhedged_spot_cns: U256,
    pub equity_cns: U256,
}

pub async fn read<P: Provider>(provider: &P, config: &Config) -> Result<Status> {
    let trader = BasisTrader::new(config.trader, provider);
    let ausd = trader.AUSD().call().await?;

    let account = trader.perplAccount().call().await?;

    // Several markets can share a cash or spot token, and counting a balance
    // twice would overstate equity. Keyed by address for that reason.
    let mut tokens: BTreeMap<Address, u8> = BTreeMap::new();
    tokens.insert(ausd, 6);

    let mut positions = Vec::new();
    let mut unhedged_spot_cns = U256::ZERO;

    for market in &config.markets {
        let registry = trader.markets(U256::from(market.perp_id)).call().await?;
        if !registry.enabled {
            continue;
        }
        tokens.insert(registry.cashToken, 6);
        if registry.spotToken != Address::ZERO {
            tokens.insert(registry.spotToken, registry.spotDecimals);
        }

        let open = trader.position(U256::from(market.perp_id)).call().await?;
        if !open.info.lotLNS.is_zero() {
            positions.push(OpenPosition {
                name: market.name.clone(),
                lots: open.info.lotLNS,
                lot_decimals: registry.lotDecimals,
                entry_pns: open.info.pricePNS,
                mark_pns: open.markPricePNS,
                price_decimals: registry.priceDecimals,
                collateral_cns: open.info.depositCNS,
                pnl_cns: open.info.pnlCNS,
            });
        }

        // Spot beyond what the short covers is naked exposure, and it is worth
        // seeing on its own line rather than folded silently into equity.
        if registry.spotToken != Address::ZERO {
            let held = IErc20::new(registry.spotToken, provider)
                .balanceOf(config.trader)
                .call()
                .await?;
            let hedged =
                lots_to_token(open.info.lotLNS, registry.spotDecimals, registry.lotDecimals);
            let naked = held.saturating_sub(hedged);
            unhedged_spot_cns += value_at_mark(
                naked,
                registry.spotDecimals,
                open.markPricePNS,
                registry.priceDecimals,
            );
        }
    }

    let mut wallet = Vec::new();
    let mut cash_cns = U256::ZERO;
    for (token, decimals) in tokens {
        let erc20 = IErc20::new(token, provider);
        let amount = erc20.balanceOf(config.trader).call().await?;
        let symbol = erc20
            .symbol()
            .call()
            .await
            .unwrap_or_else(|_| format!("{token:#x}"));

        // Stables count toward equity at the peg; the spot tokens are already
        // accounted for through the position and the unhedged line.
        if decimals == 6 {
            cash_cns += if token == ausd {
                amount
            } else {
                amount * U256::from(config.cash_peg_ppm) / U256::from(1_000_000u64)
            };
        }

        wallet.push(Holding { symbol, decimals, amount });
    }

    let position_value: I256 = positions
        .iter()
        .map(|p| I256::try_from(p.collateral_cns).unwrap_or(I256::MAX) + p.pnl_cns)
        .fold(I256::ZERO, |a, b| a + b);

    let equity = I256::try_from(cash_cns + account.balanceCNS + unhedged_spot_cns)
        .unwrap_or(I256::MAX)
        + position_value;

    Ok(Status {
        trader: config.trader,
        perpl_account_id: account.accountId,
        wallet,
        free_collateral_cns: account.balanceCNS,
        positions,
        unhedged_spot_cns,
        equity_cns: U256::try_from(equity.max(I256::ZERO)).unwrap_or(U256::ZERO),
    })
}

fn lots_to_token(lots: U256, token_decimals: u8, lot_decimals: u8) -> U256 {
    if token_decimals >= lot_decimals {
        lots * U256::from(10u64).pow(U256::from((token_decimals - lot_decimals) as u64))
    } else {
        lots / U256::from(10u64).pow(U256::from((lot_decimals - token_decimals) as u64))
    }
}

fn value_at_mark(amount: U256, token_decimals: u8, mark_pns: U256, price_decimals: u8) -> U256 {
    if amount.is_zero() || mark_pns.is_zero() {
        return U256::ZERO;
    }
    let token_scale = U256::from(10u64).pow(U256::from(token_decimals as u64));
    let price_scale = U256::from(10u64).pow(U256::from(price_decimals as u64));
    amount * mark_pns * U256::from(1_000_000u64) / (token_scale * price_scale)
}

impl Status {
    pub fn render(&self, markets: &[MarketConfig]) -> String {
        let _ = markets;
        let mut out = String::new();

        out.push_str(&format!("  BasisTrader   {:#x}\n", self.trader));
        out.push_str(&format!("  Perpl account #{}\n\n", self.perpl_account_id));

        out.push_str("  Wallet\n");
        for h in &self.wallet {
            out.push_str(&format!(
                "    {:<8} {:>22}\n",
                h.symbol,
                units::units(h.amount, h.decimals, h.decimals.min(8) as usize)
            ));
        }

        out.push_str(&format!(
            "\n  Perpl free collateral  {:>13} AUSD\n",
            units::units(self.free_collateral_cns, 6, 6)
        ));

        if self.positions.is_empty() {
            out.push_str("\n  Positions   none\n");
        } else {
            out.push_str("\n  Positions\n");
            for p in &self.positions {
                out.push_str(&format!(
                    "    {:<5} short {:>12} @ {:>12}   mark {:>12}\n",
                    p.name,
                    units::units(p.lots, p.lot_decimals, p.lot_decimals.min(8) as usize),
                    units::price(p.entry_pns, p.price_decimals),
                    units::price(p.mark_pns, p.price_decimals),
                ));
                out.push_str(&format!(
                    "          collateral {:>10} AUSD   uPnL {:>11} AUSD\n",
                    units::units(p.collateral_cns, 6, 6),
                    units::signed_units(p.pnl_cns, 6, 6),
                ));
            }
        }

        if !self.unhedged_spot_cns.is_zero() {
            out.push_str(&format!(
                "\n  Unhedged spot          {:>13} AUSD\n",
                units::units(self.unhedged_spot_cns, 6, 6)
            ));
        }

        out.push_str(&format!(
            "\n  Equity                 {:>13} AUSD\n",
            units::units(self.equity_cns, 6, 6)
        ));
        out
    }
}
