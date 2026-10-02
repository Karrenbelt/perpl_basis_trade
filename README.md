# basis_trade

Cash-and-carry between **Kuru** spot and **Perpl** perpetuals on Monad: buy the
asset on Kuru, short the matching perpetual on Perpl, collect the basis and the
funding. Both legs settle in one transaction and the trade only happens when the
realised edge, net of every fee, is positive.

```
smart_contracts/   BasisTrader.sol - the atomic enter/exit, and the edge gate
executor/          Rust service that watches the books and calls it
abi/               Perpl and Kuru ABIs this was built against
scripts/demo.sh    full lifecycle against a local Monad mainnet fork
```

## How it works

`enter` runs in this order, and reverts the whole transaction at any step:

1. Buy the spot asset on Kuru through `Router.anyToAnySwap`, with a minimum-out.
2. Size the hedge from what **actually** filled, not from the quote.
3. Short that many lots on Perpl, immediate-or-cancel **and** fill-or-kill.
4. Measure the realised edge from both fills and compare it to the market's floor.

There is no path that leaves one leg on and the other off. A short spot fill, a
short perp fill, or an edge that thinned between quote and inclusion all unwind
the whole thing, and the trade costs gas and nothing else.

`exit` is the mirror: close the short reduce-only, sell the spot back, check the
edge. `forceExit` is owner-only and skips the gate, for when a position has to
come off at a price the gate would refuse.

### The edge

```
spotNotional = cash spent on the hedged portion, converted to AUSD
perpNotional = (entry price x lots), from the position delta
edge_ppm     = (perpNotional - spotNotional) / spotNotional * 1e6
             - perplTakerFee_ppm
require(edge_ppm >= minEntryEdgePpm)      // owner-set, >= 0
```

Parts per million throughout, because that is already Perpl's own fee unit — a
schedule of `345` is 345 ppm is 3.45 bps — so fees and edge subtract without a
scale change.

Two things are deliberate here:

- **Kuru's fees and slippage are never added by hand.** They are already inside
  the ratio of cash spent to asset received, which is measured from the
  contract's own balance rather than from the venue's return value.
- **Only the hedged portion counts.** The hedge can only be sized in whole lots,
  so some of the spot fill is left over. Comparing the perp notional against
  *all* the cash spent would price that rounding dust as a total loss — 0.63% on
  ETH at a $300 clip, which swamps the basis being measured. The dust is a real
  directional exposure, and `maxHedgeDriftPpm` is what bounds it.

## What the fork turned up

Everything below was measured against a Monad mainnet fork, not assumed. It
changed the design, so it is worth knowing.

**There is no tradeable AUSD book on Kuru.** The original plan was AUSD →
USDC → asset in one routed swap, with AUSD doing double duty as spot cash and
Perpl margin. All three AUSD/USDC orderbooks fail at every size down to $50:
`0x699AbC…` and `0xb0cb29…` revert `MarketStateError()` (disabled), `0x8cF49e…`
reverts `InsufficientLiquidity()` (empty). The MON/AUSD book last traded at
0.0254 against 0.0334 on MON/USDC — a 24% gap, i.e. stale.

So the spot leg trades in **USDC** and AUSD stays behind as Perpl margin. Because
the legs are then in different stables, `cashPegPpm` converts one to the other.
The keeper passes it per call and the owner bounds it per market, so a keeper can
price a moving stable pair but cannot invent an edge by claiming a USDC is worth
two AUSD. It is static config today precisely because there is no working book to
read it from.

**Both venues are thin.** Measured depth, `smart_contracts/test/VenueDepth.t.sol`:

| book | fills | fails |
|---|---|---|
| cbBTC/USDC | $1,000 | $5,000 |
| WETH/USDC | $1,000 | $5,000 |
| Perpl BTC bid near touch | ~0.004 BTC | — |

Clip sizes in the shipped config are small for this reason, and the executor
caps inventory per market.

**Perpl conventions**, pinned against the live contract rather than inferred:

- `PositionType`: `Long = 0`, `Short = 1`.
- A short's exact entry price is `pricePNS + priceResiduePNSQ16 / 2**16`. The
  long side subtracts a whole PNS unit first, so `BasisMath` is not safe to
  reuse for longs.
- `execOrder` takes no signature — `msg.sender` is the account — so a contract
  can hold its own Perpl account and trade directly. `whitelistingEnabled()` is
  false, so opening one needs no permission.
- Taker fee 345 ppm (3.45 bps), maker 45 ppm.

**Limit offsets have to be relative.** Perpl's price decimals run from 1 on BTC
to 6 on MON, so a fixed tick offset is $0.10 of reach on one market and a
millionth of a cent on another. The executor expresses it in bps.

## Running it

Prerequisites: the [Monad fork of Foundry](https://github.com/category-labs/foundry/releases/tag/v1.5.0-monad.0.2.0)
and Rust 1.97. See [CONTRIBUTING.md](CONTRIBUTING.md) for the full setup.

```bash
make deps     # once, vendors pinned forge-std and openzeppelin-contracts
make build    # contracts, then executor
make test     # forge test + cargo test, forking Monad mainnet
make all      # fmt, lint, build, test

make fork     # a local mainnet fork on :8545, left running
make demo     # a full round trip against a fresh fork (see below)
```

### The demo

`make demo` runs the whole strategy end to end against real forked state and
reports what it made:

```
[4/7] Manufacturing a dislocation on Kuru
      a maker rests ETH spot 0.50% under the perp mark
      Perpl ETH mark   2,743.29
      Kuru  ETH ask    2,729.57

[5/7] Entering - buy the cheap spot, short the perp, one transaction
 INFO ETH   edge  +51.05bp  spot   297.4041 AUSD  perp   299.0251 AUSD  109 lots  -> ENTER
 INFO ETH   entered  tx 0x3f44...85c2

[6/7] The basis converges - spot comes back to fair
[7/7] Unwinding - close the short, sell the spot, one transaction
 INFO ETH   edge   -5.08bp  ...  -> EXIT

  Result
      opening equity    29,992.000000 AUSD
      closing equity    29,993.184255 AUSD
      net                   +1.184255 AUSD   (+39.5 bp on a 300 AUSD clip)
```

Two things in it are fork fixtures, both deliberate and both labelled in the
script:

* **A maker rests the orders.** The live basis almost never pays — that is what
  the edge gate is for — so without someone putting a price on the screen there
  is nothing for the executor to find.
* **The oracle staleness window is widened to 300s.** On mainnet an oracle
  refreshes Perpl's mark price every few seconds; a fork freezes it at the fork
  block while anvil's clock keeps running, so a scripted run starts failing with
  `MarkPriceAgeExceedsMax` partway through. Refreshing the mark properly needs a
  signed Chainlink report that cannot be forged, so the demo widens the window
  instead, as the exchange owner, to the maximum the contract allows. Nothing
  about the trade or the edge arithmetic changes.

Everything else is the real Perpl exchange and the real Kuru books.

The shape of the result is the strategy working as intended: the basis is banked
at entry, and realised when the two prices converge and the position comes off.
The exit costs a few bps, which is why the market's exit floor is set negative —
a floor of zero would refuse every unwind and strand the position.

The fork must be **fresh**. Perpl rejects an order whose mark price is stale and a
fork's oracle is frozen at the fork block, so a fork left idle starts failing with
`MarkPriceAgeExceedsMax`. `demo.sh` restarts it for this reason, and widens the
window on top. For deterministic tests, pin `MONAD_FORK_BLOCK`.

Point `MONAD_RPC_URL` at mainnet or at a *freshly started* anvil. Forking the
local anvil after `demo.sh` has traded against it inherits the drained books and
the open position, and the suite fails on venue state rather than on code.

Executor, standalone:

```bash
cd executor
cargo run -- --config config/local.toml status           # balances, positions, equity
cargo run -- --config config/local.toml status --equity  # just the number, for scripts
KEEPER_PRIVATE_KEY=0x… cargo run -- --config config/local.toml scan
KEEPER_PRIVATE_KEY=0x… cargo run -- --config config/local.toml enter --perp-id 20
KEEPER_PRIVATE_KEY=0x… cargo run -- --config config/local.toml exit  --perp-id 20
KEEPER_PRIVATE_KEY=0x… cargo run -- --config config/local.toml run   # the loop
```

`dry_run = true` in the config is the default and the safe one; `--broadcast`
overrides it for a single invocation, so sending transactions is a deliberate act
at the command line rather than an edit that outlives the session. Without a key
the executor can still scan and report status.

`status` values everything in AUSD — the unit the perp settles in and the edge
gate measures against — converting cash held in another stable at the configured
peg. It breaks out unhedged spot on its own line rather than folding it silently
into equity, because spot beyond what the short covers is naked exposure.

### How the executor decides

It does not reimplement the edge calculation. It builds the exact call it would
send and runs it through `eth_call`: the contract either returns the `Fill` it
would produce, edge included, or reverts with `EdgeTooThin(edge, floor)`, which
carries the live edge anyway. The number logged is the number the chain would
enforce, and the two cannot disagree. Perpl's own error set is decoded too, so a
blocked market says `MarkPriceAgeExceedsMax` or
`UnmatchedLotRemainsInFillOrKill` rather than a bare selector.

## Deployed addresses (Monad mainnet, chain 143)

| | |
|---|---|
| AUSD (Perpl collateral) | `0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a` |
| USDC (spot cash) | `0x754704Bc059F8C67012fEd69BC8A327a5aafb603` |
| Perpl Exchange | `0x34B6552d57a35a1D042CcAe1951BD1C370112a6F` |
| Kuru Router | `0xd651346d7c789536ebf06dc72aE3C8502cd695CC` |
| Kuru MarginAccount | `0x2A68ba1833cDf93fa9Da1EEbd7F46242aD8E90c5` |
| cbBTC/USDC book | `0x40c49F171202F91ff5d2faE34c22dD2BFdD22aF0` |
| WETH/USDC book | `0xa6aFD386135B7D41A6C40C525abC4A1019b0D132` |
| MON/USDC book | `0x065C9d28E428A0db40191a54d33d5b7c71a9C394` |

Markets are the three where a liquid Kuru spot book and a live Perpl perpetual
both exist: **BTC** (perp 1, cbBTC), **ETH** (perp 20, WETH), **MON** (perp 10,
native).

## Known limits

- **Funding is upside, not a gate.** Entry is decided on instantaneous basis net
  of fees. A position that is basis-flat but funding-positive will not be
  entered.
- **`cashPegPpm` is static.** Nothing on-chain to read it from. Its band is the
  protection; keep the band tight and revisit if an AUSD book revives.
- **Margin is not managed automatically.** `topUpPosition` exists and the owner
  can call it, but nothing watches the maintenance margin yet.
- **One Perpl account.** Perpl keys accounts by address, so the contract has
  exactly one and all markets share its collateral.
- **The MON leg is native.** The route handles it, but it has had less exercise
  than the ERC20 paths.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Note in particular that the tests fork
real Monad mainnet state rather than mocking the venues, which puts some
constraints on how they are written.

## License

MIT — see [LICENSE](LICENSE).
