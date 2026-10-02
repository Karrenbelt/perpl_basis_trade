//! Deciding whether a trade is on, by asking the contract.
//!
//! The executor deliberately does not reimplement the edge calculation. It
//! builds the exact call it would send and runs it through `eth_call`; the
//! contract either returns the `Fill` it would have produced - realised edge
//! included - or reverts with `EdgeTooThin(edge, floor)`, which carries the
//! live edge anyway. Either way the number the executor logs is the number the
//! chain would have enforced, and the two can never disagree.

use alloy::{
    primitives::{Address, U256},
    providers::Provider,
    sol_types::SolInterface,
};

use crate::bindings::{
    BasisTrader::{self, BasisTraderErrors, EnterParams, ExitParams, Fill},
    PerplErrors::PerplErrorsErrors,
};

#[derive(Debug)]
pub enum Decision {
    /// The call would succeed. `fill` is what it would produce.
    Fire(Fill),
    /// Rejected by the on-chain edge gate, which told us by how much.
    EdgeTooThin { edge_ppm: i64, floor_ppm: i64 },
    /// Rejected for anything else - a leg that would not fill, a book that
    /// moved, a market that is paused.
    Blocked(String),
}

pub async fn simulate_enter<P: Provider>(
    provider: &P,
    trader: Address,
    keeper: Address,
    params: EnterParams,
) -> Decision {
    let contract = BasisTrader::new(trader, provider);
    match contract.enter(params).from(keeper).call().await {
        Ok(fill) => Decision::Fire(fill),
        Err(err) => classify(err),
    }
}

pub async fn simulate_exit<P: Provider>(
    provider: &P,
    trader: Address,
    keeper: Address,
    params: ExitParams,
) -> Decision {
    let contract = BasisTrader::new(trader, provider);
    match contract.exit(params).from(keeper).call().await {
        Ok(fill) => Decision::Fire(fill),
        Err(err) => classify(err),
    }
}

/// Pull the structured reason out of a reverted simulation.
///
/// `EdgeTooThin` is the expected answer most of the time - it is the gate doing
/// its job - so it is separated from the failures that mean something is wrong
/// with the call itself.
fn classify(err: alloy::contract::Error) -> Decision {
    if let Some(data) = revert_data(&err) {
        if let Ok(decoded) = BasisTraderErrors::abi_decode(&data) {
            return match decoded {
                BasisTraderErrors::EdgeTooThin(e) => Decision::EdgeTooThin {
                    edge_ppm: i64::try_from(e.edgePpm).unwrap_or(i64::MIN),
                    floor_ppm: i64::try_from(e.minPpm).unwrap_or(i64::MIN),
                },
                other => Decision::Blocked(format!("{other:?}")),
            };
        }
        // Most rejections come from Perpl rather than from our own gate - a
        // stale oracle, a book that moved under the fill-or-kill - so the
        // exchange's error set is tried before giving up on the selector.
        if let Ok(decoded) = PerplErrorsErrors::abi_decode(&data) {
            return Decision::Blocked(format!("perpl: {decoded:?}"));
        }
        if data.len() >= 4 {
            return Decision::Blocked(format!("unrecognised revert, selector 0x{}", hex4(&data)));
        }
    }
    Decision::Blocked(err.to_string())
}

fn revert_data(err: &alloy::contract::Error) -> Option<alloy::primitives::Bytes> {
    match err {
        alloy::contract::Error::TransportError(transport) => transport
            .as_error_resp()
            .and_then(|resp| resp.as_revert_data()),
        _ => None,
    }
}

fn hex4(data: &[u8]) -> String { data[..4].iter().map(|b| format!("{b:02x}")).collect() }

/// Smallest acceptable output of a leg, given a reference price and a slippage
/// allowance in bps.
pub fn apply_slippage_floor(expected: U256, bps: u64) -> U256 {
    let numerator = U256::from(10_000u64.saturating_sub(bps));
    expected * numerator / U256::from(10_000u64)
}
