# Contributing to basis_trade

This repo holds two halves of one strategy: a Solidity contract that executes a
Kuru/Perpl cash-and-carry atomically, and a Rust service that decides when to
call it. They are coupled — the executor generates its bindings from the
contract's compiled artifact — so most changes touch both, and the tooling
reflects that.

Read [`README.md`](README.md) first. In particular the *What the fork turned up*
section: several non-obvious constraints (no tradeable AUSD book, thin depth on
both venues, Perpl's position-enum and price-residue conventions) were measured
rather than assumed, and a change that contradicts one of them is probably wrong.

## Prerequisites

* The **Monad fork of Foundry** —
  [v1.5.0-monad.0.2.0](https://github.com/category-labs/foundry/releases/tag/v1.5.0-monad.0.2.0).
  Upstream Foundry will not do: the test suite forks Monad mainnet and needs the
  custom `anvil` on your `PATH`.
* **Rust 1.97**, pinned in [`rust-toolchain.toml`](rust-toolchain.toml).
* The nightly used for formatting, matching `dex-sdk` so the two repos format
  alike:
  ```bash
  rustup toolchain install nightly-2026-08-22 --component rustfmt,clippy
  ```

Then, once:

```bash
make deps      # vendors pinned forge-std and openzeppelin-contracts
```

`smart_contracts/lib/` is gitignored rather than tracked as submodules, so
`make deps` is what reconstitutes it on a fresh clone. The versions are pinned in
the [`makefile`](makefile); bump them there, not by hand.

## Local checks

```bash
make build      # contracts, then executor
make fmt        # forge fmt + cargo +nightly fmt
make fmt-check  # what CI runs - fails instead of rewriting
make lint       # forge lint + cargo clippy -D warnings
make test       # forge test + cargo test

make all        # fmt, lint, build, test
```

**Commit the result of `make fmt`.** CI runs `make fmt-check` and fails on a
dirty tree.

Order matters in one place: the executor's `sol!` bindings are generated from
`smart_contracts/out/BasisTrader.sol/BasisTrader.json`, so the contracts must be
compiled before the Rust side will build. Every Rust target in the makefile
depends on `build-sc` for that reason — if you run `cargo` directly and get a
missing-artifact error, that is why.

## Tests fork Monad mainnet

There are no mocks for the venues. Every integration test runs against real Perpl
and Kuru state, because the whole point is that the contract's edge arithmetic
agrees with what the chains actually do.

```bash
make test                                   # forks https://rpc.monad.xyz
MONAD_RPC_URL=http://127.0.0.1:8545 make test   # forks a local anvil
```

Three things to know:

* **Run a local fork while iterating.** `make fork` starts one on `:8545` and
  leaves it running. It is much faster than the public RPC and does not hammer it.
* **Do not point the tests at a fork `make demo` has traded against.** The demo
  moves books and opens a position; a suite forked from that state fails on venue
  conditions rather than on your code. Restart it — `make demo` always does.
* **Pin `MONAD_FORK_BLOCK` for determinism.** Without it the tests fork the
  latest block, and anything that depends on live market conditions drifts.
  Which is why tests should not depend on them — see below.

### Writing tests against live state

A test must assert *our* behaviour, not the market's mood. Two rules earned the
hard way:

* **Derive prices from live state, never hardcode them.** A price that was a
  discount at one fork block is a premium at another, and the assertion inverts
  silently. `_ticksFromMark` in
  [`test/BasisTrader.t.sol`](smart_contracts/test/BasisTrader.t.sol) is the
  pattern — it also snaps to the book's tick grid, which Kuru rejects otherwise.
* **Manufacture the condition you mean to test.** Asserting "the live basis is
  negative so entry is refused" tests the market. Setting an unreachable
  `minEntryEdgePpm` and asserting the refusal tests the gate. `_seedCheapAsk` and
  `_seedRichBid` in [`test/Fixtures.sol`](smart_contracts/test/Fixtures.sol)
  exist so the profitable cases can be exercised at all; both have to clear the
  opposing side of the book first, because Kuru rejects a post-only order that
  would cross.

AUSD cannot be `deal`'d — it is a proxy whose balance mapping `stdstore` cannot
find — so test capital is moved off a live holder instead. `_fundAusd` walks a
list of whales. If they ever run dry at some fork block it fails loudly rather
than silently funding zero.

## The demo

`make demo` is the end-to-end proof, and it is also the fastest way to see a
change working: it forks, deploys, manufactures a dislocation on Kuru, enters,
converges the book, unwinds, and prints the round-trip P&L.

It depends on three things that are easy to break:

* **`scripts/demo.sh` derives every price from the live Perpl mark** and snaps it
  to the Kuru book's tick grid. Hardcoding a price works until the fork moves,
  and then the "cheap" ask is a rich one and the demo quietly stops proving
  anything.
* **The market's `minExitEdgePpm` is negative on purpose** — see the comment in
  [`script/Deploy.s.sol`](smart_contracts/script/Deploy.s.sol). The basis is
  banked at entry; once it has converged the unwind is worth roughly minus the
  taker fee. A floor of zero refuses every exit and strands the position.

* **It widens Perpl's oracle staleness window to 300s** before doing anything
  else, as the exchange owner. A fork's oracle is frozen at the fork block while
  anvil's clock keeps running, and the default 60s window expires partway through
  the run. Refreshing the mark price properly would need a signed Chainlink
  report, which cannot be forged. If you add steps to the demo and it starts
  failing with `MarkPriceAgeExceedsMax`, the run has simply grown past 300s —
  that is the contract's own ceiling, so the fix is a shorter demo, not a wider
  window.

If the demo starts reporting a loss, suspect the book-seeding before the
contract: the entry eats the cheap ask it was given, and if nothing restores a
bid afterwards the unwind sells into a vacuum.

## Lints

`forge lint` is configured in [`foundry.toml`](smart_contracts/foundry.toml) to
exclude `mixed-case-variable` and `mixed-case-function`. This is deliberate:
Perpl and Kuru name their ABI fields `lotLNS`, `pricePNS`, `amountCNS`, and the
structs here must encode identically or the calls revert on decode. The scale
suffixes carry through into our own helpers on purpose, so a value's units are
visible at every call site.

Everything else is expected to be clean. If a cast is genuinely safe, bound it
first and then annotate the line — `forge-lint: disable-next-line(...)` applies to
the *immediately* following line, so the justification comment goes above the
directive, not between it and the code.

## Branching and commits

Branch names follow `<type>/<short-description>`, e.g. `feat/funding-aware-entry`,
`fix/exit-route-reversal`, `chore/bump-forge-std`.

Commit messages follow the conventional-commit style used across the Perpl repos:

```
feat(executor): cap inventory per market
fix(BasisTrader): measure edge against the hedged share only
chore: pin forge-std
```

Use `feat`, `fix`, `chore`, `docs`, `refactor` or `test`, with an optional scope —
either a component (`BasisTrader`, `executor`, `BasisMath`) or a ticket ID.

## Things to be careful about

* **The edge calculation lives in one place.** The executor deliberately does not
  reimplement it; it simulates the real call and reads the contract's own answer.
  Keep it that way — two implementations of the same arithmetic will disagree,
  and the one that is wrong will be the one that is not enforcing anything.
* **Both legs or neither.** Any new path through `enter`/`exit` must preserve
  that a failure anywhere unwinds the whole transaction. There is deliberately no
  partial-fill-and-rebalance mode.
* **`BasisMath` is short-only.** A short's exact entry price is
  `pricePNS + priceResiduePNSQ16 / 2**16`; the long side subtracts a whole PNS
  unit first. The helpers are not safe to reuse for longs without that branch.
* **Keeper versus owner.** A keeper may enter and exit; only the owner may move
  funds, change the market registry, or `forceExit` past the edge gate. New
  functions should land on the right side of that line.
* **`cashPegPpm` is keeper-supplied and owner-bounded.** If you widen a band,
  you are widening how far a keeper can misprice the edge.

## License

By contributing, you agree that your contributions are licensed under the terms
in [LICENSE](LICENSE).
