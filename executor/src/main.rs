//! Basis-trade executor.
//!
//! Watches the Kuru spot books against the matching Perpl perpetuals and calls
//! `BasisTrader.enter` when the cash-and-carry pays, `exit` when the unwind
//! does. Every decision is made by simulating the real call against the current
//! block, so the executor never forms an opinion the contract would not agree
//! with - and when it does fire, the same gate runs again inside the
//! transaction.

mod bindings;
mod config;
mod quote;
mod status;
mod strategy;
mod units;

use std::{path::PathBuf, time::Duration};

use alloy::{
    primitives::{Address, U256},
    providers::{Provider, ProviderBuilder},
    signers::local::PrivateKeySigner,
};
use anyhow::Context;
use clap::{Parser, Subcommand};
use tracing::{info, warn};

use crate::{
    bindings::{BasisTrader, IPerplRead},
    config::{Config, MarketConfig},
    quote::Decision,
    strategy::PerpSnapshot,
};

#[derive(Parser)]
#[command(name = "basis-executor", about = "Kuru/Perpl basis trade executor")]
struct Cli {
    #[arg(long, default_value = "config/local.toml", env = "BASIS_CONFIG")]
    config: PathBuf,

    /// Keeper key. Required to broadcast; without it the executor can only
    /// scan.
    #[arg(long, env = "KEEPER_PRIVATE_KEY")]
    private_key: Option<String>,

    /// Send transactions, overriding `dry_run` in the config file.
    ///
    /// The config defaults to dry run, and an override is a deliberate act at
    /// the command line rather than an edit that outlives the session.
    #[arg(long)]
    broadcast: bool,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Price every market once and print what the contract would do.
    Scan,
    /// Scan on a loop, firing whatever clears the on-chain gate.
    Run,
    /// Enter one market once, if the gate lets it through.
    Enter {
        #[arg(long)]
        perp_id: u64,
    },
    /// Balances, open positions and total equity.
    Status {
        /// Print only the equity in AUSD base units, for scripting.
        #[arg(long)]
        equity: bool,
    },
    /// Unwind a market's position.
    Exit {
        #[arg(long)]
        perp_id: u64,
        /// Skip the edge gate. Owner key only.
        #[arg(long)]
        force: bool,
    },
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Compact on purpose: this is read in a terminal, not grepped out of a log
    // file. `RUST_LOG` still turns the detail back on.
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "basis_executor=info".into()),
        )
        .without_time()
        .with_target(false)
        .init();

    let cli = Cli::parse();
    let mut config = Config::load(&cli.config)?;
    if cli.broadcast {
        config.dry_run = false;
    }

    let signer: Option<PrivateKeySigner> = match &cli.private_key {
        Some(key) => Some(key.parse().context("parsing KEEPER_PRIVATE_KEY")?),
        None => None,
    };
    let keeper = signer
        .as_ref()
        .map(|s| s.address())
        .unwrap_or(Address::ZERO);

    // Erased so the signing and read-only builds are the same type: the scan
    // path works without a key, the firing path needs one, and everything
    // downstream takes whichever it was given.
    let provider = match signer.clone() {
        Some(s) => ProviderBuilder::new()
            .wallet(s)
            .connect(&config.rpc_url)
            .await?
            .erased(),
        None => ProviderBuilder::new()
            .connect(&config.rpc_url)
            .await?
            .erased(),
    };

    // Only the long-running mode announces itself; a one-shot command should
    // print its answer and nothing else.
    if matches!(cli.command, Command::Run) {
        info!(
            "watching {} markets on {} as {keeper:#x}{}",
            config.markets.len(),
            config.rpc_url,
            if config.dry_run { " (dry run)" } else { "" }
        );
    }

    match cli.command {
        Command::Scan => scan_once(&provider, &config, keeper).await,
        Command::Run => run_loop(&provider, &config, keeper, signer.is_some()).await,
        Command::Enter { perp_id } => enter_once(&provider, &config, keeper, perp_id).await,
        Command::Status { equity } => show_status(&provider, &config, equity).await,
        Command::Exit { perp_id, force } => {
            unwind(&provider, &config, keeper, perp_id, force).await
        },
    }
}

async fn scan_once<P: Provider>(
    provider: &P,
    config: &Config,
    keeper: Address,
) -> anyhow::Result<()> {
    for market in &config.markets {
        match evaluate(provider, config, market, keeper, 1).await {
            Ok((decision, snapshot)) => report(market, &decision, &snapshot, "ENTER"),
            Err(err) => warn!(market = %market.name, %err, "could not price market"),
        }
    }
    Ok(())
}

async fn run_loop<P: Provider>(
    provider: &P,
    config: &Config,
    keeper: Address,
    can_sign: bool,
) -> anyhow::Result<()> {
    if !can_sign && !config.dry_run {
        anyhow::bail!("dry_run is off but no keeper key was supplied");
    }

    let mut request_id: u64 = 1;
    loop {
        for market in &config.markets {
            request_id += 1;
            let (decision, snapshot) =
                match evaluate(provider, config, market, keeper, request_id).await {
                    Ok(result) => result,
                    Err(err) => {
                        warn!(market = %market.name, %err, "could not price market");
                        continue;
                    },
                };
            report(market, &decision, &snapshot, "ENTER");

            if let Decision::Fire(_) = decision {
                if config.dry_run {
                    info!(market = %market.name, "dry run, not broadcasting");
                    continue;
                }
                fire(provider, config, market, keeper, request_id).await?;
            }
        }
        tokio::time::sleep(Duration::from_millis(config.poll_interval_ms)).await;
    }
}

/// Price one market by simulating the real `enter` call.
async fn evaluate<P: Provider>(
    provider: &P,
    config: &Config,
    market: &MarketConfig,
    keeper: Address,
    request_id: u64,
) -> anyhow::Result<(Decision, PerpSnapshot)> {
    let snapshot = read_perp(provider, config.perpl_exchange, market.perp_id).await?;

    let open = open_lots(provider, config.trader, market.perp_id).await?;
    if open >= market.max_position_lots {
        return Ok((
            Decision::Blocked(format!(
                "position cap reached: {open} of {} lots",
                market.max_position_lots
            )),
            snapshot,
        ));
    }

    let params = strategy::build_enter(market, &snapshot, config.cash_peg_ppm, request_id);
    let decision = quote::simulate_enter(provider, config.trader, keeper, params).await;
    Ok((decision, snapshot))
}

/// Lots of short the trader already carries on `perp_id`.
async fn open_lots<P: Provider>(
    provider: &P,
    trader: Address,
    perp_id: u64,
) -> anyhow::Result<U256> {
    let contract = BasisTrader::new(trader, provider);
    let result = contract.position(U256::from(perp_id)).call().await?;
    Ok(result.info.lotLNS)
}

async fn show_status<P: Provider>(
    provider: &P,
    config: &Config,
    equity_only: bool,
) -> anyhow::Result<()> {
    let status = status::read(provider, config).await?;
    if equity_only {
        println!("{}", status.equity_cns);
    } else {
        println!("\n{}", status.render(&config.markets));
    }
    Ok(())
}

async fn enter_once<P: Provider>(
    provider: &P,
    config: &Config,
    keeper: Address,
    perp_id: u64,
) -> anyhow::Result<()> {
    let market = config
        .markets
        .iter()
        .find(|m| m.perp_id == perp_id)
        .with_context(|| format!("no market configured for perp {perp_id}"))?;

    let (decision, snapshot) = evaluate(provider, config, market, keeper, 1).await?;
    report(market, &decision, &snapshot, "ENTER");

    match decision {
        Decision::Fire(_) if !config.dry_run => fire(provider, config, market, keeper, 1).await,
        Decision::Fire(_) => {
            info!("dry run, not broadcasting");
            Ok(())
        },
        _ => Ok(()),
    }
}

async fn fire<P: Provider>(
    provider: &P,
    config: &Config,
    market: &MarketConfig,
    keeper: Address,
    request_id: u64,
) -> anyhow::Result<()> {
    let snapshot = read_perp(provider, config.perpl_exchange, market.perp_id).await?;
    let params = strategy::build_enter(market, &snapshot, config.cash_peg_ppm, request_id);

    let contract = BasisTrader::new(config.trader, provider);
    let pending = contract.enter(params).from(keeper).send().await?;
    let receipt = pending.get_receipt().await?;
    info!(
        "{:<4}  entered  tx {:#x}{}",
        market.name,
        receipt.transaction_hash,
        if receipt.status() { "" } else { "  (REVERTED)" }
    );
    Ok(())
}

async fn unwind<P: Provider>(
    provider: &P,
    config: &Config,
    keeper: Address,
    perp_id: u64,
    force: bool,
) -> anyhow::Result<()> {
    let market = config
        .markets
        .iter()
        .find(|m| m.perp_id == perp_id)
        .with_context(|| format!("no market configured for perp {perp_id}"))?;

    let snapshot = read_perp(provider, config.perpl_exchange, perp_id).await?;
    // Zero means "sell whatever the contract is holding", which is what an
    // operator unwinding by hand almost always wants.
    let params = strategy::build_exit(market, &snapshot, U256::ZERO, config.cash_peg_ppm, 1);

    let contract = BasisTrader::new(config.trader, provider);

    // Simulate before broadcasting even when firing for real. An unwind that
    // the gate would refuse should cost nothing - the point of finding out here
    // is to not pay gas to be told no on-chain. `--force` deliberately skips
    // the gate, so it skips this check too.
    if !force {
        let decision = quote::simulate_exit(provider, config.trader, keeper, params.clone()).await;
        report(market, &decision, &snapshot, "EXIT");
        if !matches!(decision, Decision::Fire(_)) {
            info!("unwind would be rejected, not broadcasting - use --force to override");
            return Ok(());
        }
    }

    if config.dry_run {
        info!("dry run, not broadcasting");
        return Ok(());
    }

    let pending = if force {
        contract.forceExit(params).from(keeper).send().await?
    } else {
        contract.exit(params).from(keeper).send().await?
    };
    let receipt = pending.get_receipt().await?;
    info!(
        "{:<4}  exited{}   tx {:#x}{}",
        market.name,
        if force { " (forced)" } else { "" },
        receipt.transaction_hash,
        if receipt.status() { "" } else { "  (REVERTED)" }
    );
    Ok(())
}

async fn read_perp<P: Provider>(
    provider: &P,
    exchange: Address,
    perp_id: u64,
) -> anyhow::Result<PerpSnapshot> {
    let perpl = IPerplRead::new(exchange, provider);
    let info = perpl.getPerpetualInfoV2(U256::from(perp_id)).call().await?;
    let fee = perpl.getTakerFee(U256::from(perp_id)).call().await?;
    Ok(PerpSnapshot::from_info(&info, fee.to::<u64>()))
}

/// One line per market, aligned so a column of them reads as a table.
///
/// Edges are shown in basis points rather than the ppm the contract enforces:
/// the gate's unit is ppm because that is Perpl's fee unit, but nobody quotes a
/// basis in millionths.
fn report(market: &MarketConfig, decision: &Decision, snapshot: &PerpSnapshot, action: &str) {
    let fee = units::ppm_as_bps(snapshot.taker_fee_ppm as i64);
    match decision {
        Decision::Fire(fill) => {
            let edge = i64::try_from(fill.edgePpm).unwrap_or_default();
            info!(
                "{:<4}  edge {:>9}  spot {:>10} AUSD  perp {:>10} AUSD  {:>8} lots  (perp taker \
                 {})  -> {}",
                market.name,
                units::ppm_as_bps(edge),
                units::units(fill.spotNotionalCNS, 6, 4),
                units::units(fill.perpNotionalCNS, 6, 4),
                fill.lotLNS,
                fee,
                action,
            );
        },
        Decision::EdgeTooThin { edge_ppm, floor_ppm } => info!(
            "{:<4}  edge {:>9}  floor {:>9}  (perp taker {})  -> skip",
            market.name,
            units::ppm_as_bps(*edge_ppm),
            units::ppm_as_bps(*floor_ppm),
            fee,
        ),
        Decision::Blocked(reason) => warn!("{:<4}  blocked: {reason}", market.name),
    }
}
