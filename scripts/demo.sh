#!/usr/bin/env bash
# A full basis trade against a local Monad mainnet fork, narrated.
#
# Forks mainnet, funds and deploys, manufactures a dislocation on Kuru, enters
# the trade, lets the basis converge, unwinds, and reports what the round trip
# made.
#
# Everything it touches is real: real Perpl, real Kuru, real books. The only
# fiction is the maker who rests the orders, and that is the point — the live
# basis almost never pays, so without someone putting a price on the screen
# there is nothing for the executor to find.
#
# The fork has to be fresh. Perpl rejects an order whose mark price is stale, and
# a fork's oracle state is frozen while anvil's clock keeps running, so the whole
# sequence runs in one go — and even then it widens the staleness window first
# (see `relax_oracle_window`).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RPC="${RPC:-http://127.0.0.1:8545}"
FORK_RPC="${FORK_RPC:-https://rpc.monad.xyz}"
LOG="${LOG:-/tmp/basis-anvil.log}"

# The market the demo trades. ETH has the most forgiving combination of Perpl
# book depth and Kuru tick size.
PERP_ID=20
MARKET_NAME=ETH

# anvil's deterministic accounts
DEPLOYER_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
KEEPER_PK=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
KEEPER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
MAKER_PK=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
MAKER=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC

AUSD=0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a
USDC=0x754704Bc059F8C67012fEd69BC8A327a5aafb603
WETH=0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242
BOOK=0xa6aFD386135B7D41A6C40C525abC4A1019b0D132
PERPL=0x34B6552d57a35a1D042CcAe1951BD1C370112a6F
PERPL_OWNER=0xd0a0205e9188998E0bE7F2600a715aD3CD289Cb1
AUSD_WHALE=0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e

# Balance-mapping slots, found by scanning the live tokens. AUSD is a proxy
# whose slot resists scanning, so it is funded by moving real balance instead.
USDC_SLOT=9
WETH_SLOT=51

CONFIG="$ROOT/executor/config/local.toml"
EXEC=(cargo run --quiet --manifest-path "$ROOT/executor/Cargo.toml" -- --config "$CONFIG")

# On mainnet an oracle refreshes the mark price every few seconds. A fork freezes
# it at the fork block while anvil's clock keeps running, so Perpl starts
# rejecting orders with `MarkPriceAgeExceedsMax` partway through a scripted run.
#
# The honest fix would be to refresh the mark, but that needs a signed Chainlink
# report this script cannot produce. So it widens the staleness window instead,
# as the exchange owner, to the 300s the contract allows. Nothing about the trade
# or the edge arithmetic changes; it only stops the demo racing a clock that only
# moves because anvil's does.
relax_oracle_window() {
  cast rpc anvil_impersonateAccount $PERPL_OWNER --rpc-url "$RPC" >/dev/null
  cast rpc anvil_setBalance $PERPL_OWNER 0xde0b6b3a7640000 --rpc-url "$RPC" >/dev/null
  for id in 1 10 20; do
    cast send $PERPL "setPriceMaxAge(uint256,uint256)" "$id" 300 \
      --from $PERPL_OWNER --unlocked --rpc-url "$RPC" >/dev/null
  done
  cast rpc anvil_stopImpersonatingAccount $PERPL_OWNER --rpc-url "$RPC" >/dev/null
}

bold()  { printf '\033[1m%s\033[0m\n' "$1"; }
step()  { printf '\n\033[1;36m%s\033[0m %s\n' "$1" "$2"; }
note()  { printf '      %s\n' "$1"; }
rule()  { printf '      %s\n' "──────────────────────────────────────────────"; }

# --------------------------------------------------------------------------

printf '\n'
bold "  Kuru / Perpl basis trade — local Monad mainnet fork"
printf '  buy spot on Kuru, short the perp on Perpl, unwind when it converges\n'

step "[1/7]" "Forking Monad mainnet"
pkill -f "anvil --fork-url" 2>/dev/null || true
sleep 1
nohup anvil --fork-url "$FORK_RPC" --port 8545 --chain-id 143 >"$LOG" 2>&1 &
for _ in $(seq 1 40); do cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
note "block $(cast block-number --rpc-url "$RPC")"
relax_oracle_window
note "oracle staleness window widened to 300s (fork fixture, see script)"

step "[2/7]" "Funding accounts and deploying"
cast rpc anvil_impersonateAccount $AUSD_WHALE --rpc-url "$RPC" >/dev/null
cast rpc anvil_setBalance $AUSD_WHALE 0xde0b6b3a7640000 --rpc-url "$RPC" >/dev/null
cast send $AUSD "transfer(address,uint256)" $DEPLOYER 20000000000 \
  --from $AUSD_WHALE --unlocked --rpc-url "$RPC" >/dev/null
cast rpc anvil_stopImpersonatingAccount $AUSD_WHALE --rpc-url "$RPC" >/dev/null
cast rpc anvil_setStorageAt $USDC "$(cast index address $DEPLOYER $USDC_SLOT)" \
  0x0000000000000000000000000000000000000000000000000000000ba43b7400 --rpc-url "$RPC" >/dev/null
cast rpc anvil_setStorageAt $WETH "$(cast index address $MAKER $WETH_SLOT)" \
  0x0000000000000000000000000000000000000000000000056bc75e2d63100000 --rpc-url "$RPC" >/dev/null
cast rpc anvil_setStorageAt $USDC "$(cast index address $MAKER $USDC_SLOT)" \
  0x000000000000000000000000000000000000000000000000000000174876e800 --rpc-url "$RPC" >/dev/null

TRADER=$(cd "$ROOT/smart_contracts" && \
  PRIVATE_KEY=$DEPLOYER_PK KEEPER=$KEEPER AUSD_SEED=10000000000 USDC_SEED=20000000000 \
  forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC" --broadcast 2>&1 \
  | sed -n 's/.*BasisTrader \(0x[0-9a-fA-F]*\).*/\1/p' | head -1)
sed -i.bak "s|^trader = .*|trader = \"$TRADER\"|" "$CONFIG" && rm -f "$CONFIG.bak"
note "BasisTrader  $TRADER"

step "[3/7]" "Opening balance sheet"
"${EXEC[@]}" status
EQ_OPEN=$("${EXEC[@]}" status --equity)

# Kuru price ticks for a given percentage of the Perpl mark, snapped to the
# book's tick grid. Derived live so the demo survives the fork moving.
ticks_at() {
  local bps=$1
  local info mark price_dec prec tick
  info=$(cast call $PERPL \
    "getPerpetualInfoV2(uint256)((string,string,uint256,uint256,bytes32,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,int16,uint256,uint8,uint256,uint256,uint256,uint256,uint256,uint256,bool,uint256))" \
    $PERP_ID --rpc-url "$RPC" | tr -d '()' | tr ',' '\n' | sed 's/\[.*\]//' | tr -d ' ')
  price_dec=$(echo "$info" | sed -n '3p')
  mark=$(echo "$info" | sed -n '12p')
  prec=$(cast call $BOOK "getMarketParams()(uint32,uint96,address,uint256,address,uint256,uint32,uint96,uint96,uint256,uint256)" \
    --rpc-url "$RPC" | sed -n '1p' | sed 's/\[.*\]//' | tr -d ' ')
  tick=$(cast call $BOOK "getMarketParams()(uint32,uint96,address,uint256,address,uint256,uint32,uint96,uint96,uint256,uint256)" \
    --rpc-url "$RPC" | sed -n '7p' | sed 's/\[.*\]//' | tr -d ' ')
  python3 -c "
t = $mark * $prec // 10**$price_dec
t = t * $bps // 10000
print(t // $tick * $tick)"
}

mark_price() {
  cast call $PERPL \
    "getPerpetualInfoV2(uint256)((string,string,uint256,uint256,bytes32,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,int16,uint256,uint8,uint256,uint256,uint256,uint256,uint256,uint256,bool,uint256))" \
    $PERP_ID --rpc-url "$RPC" | tr -d '()' | tr ',' '\n' | sed 's/\[.*\]//' | tr -d ' ' | sed -n '12p'
}

step "[4/7]" "Manufacturing a dislocation on Kuru"
CHEAP=$(ticks_at 9950)
note "a maker rests $MARKET_NAME spot 0.50% under the perp mark"
(cd "$ROOT/smart_contracts" && \
  PRIVATE_KEY=$MAKER_PK BOOK=$BOOK TOKEN=$WETH PRICE_TICKS=$CHEAP SIZE=5000000000 \
  forge script script/SeedBook.s.sol:SeedAsk --rpc-url "$RPC" --broadcast >/dev/null 2>&1)
note "Perpl $MARKET_NAME mark   $(python3 -c "print(f'{$(mark_price)/100:,.2f}')")"
note "Kuru  $MARKET_NAME ask    $(python3 -c "print(f'{$CHEAP/10000:,.2f}')")"

step "[5/7]" "Entering — buy the cheap spot, short the perp, one transaction"
KEEPER_PRIVATE_KEY=$KEEPER_PK "${EXEC[@]}" --broadcast enter --perp-id $PERP_ID
"${EXEC[@]}" status

step "[6/7]" "The basis converges — spot comes back to fair"
FAIR=$(ticks_at 10000)
note "the maker now bids at the mark, $(python3 -c "print(f'{$FAIR/10000:,.2f}')")"
(cd "$ROOT/smart_contracts" && \
  PRIVATE_KEY=$MAKER_PK BOOK=$BOOK TOKEN=$USDC PRICE_TICKS=$FAIR SIZE=5000000000 \
  forge script script/SeedBook.s.sol:SeedBid --rpc-url "$RPC" --broadcast >/dev/null 2>&1)

step "[7/7]" "Unwinding — close the short, sell the spot, one transaction"
KEEPER_PRIVATE_KEY=$KEEPER_PK "${EXEC[@]}" --broadcast exit --perp-id $PERP_ID
"${EXEC[@]}" status
EQ_CLOSE=$("${EXEC[@]}" status --equity)

printf '\n'
bold "  Result"
python3 - "$EQ_OPEN" "$EQ_CLOSE" <<'PY'
import sys
open_cns, close_cns = int(sys.argv[1]), int(sys.argv[2])
delta = close_cns - open_cns
clip = 300_000_000  # the ETH clip in config/local.toml
print(f"      opening equity   {open_cns/1e6:>14,.6f} AUSD")
print(f"      closing equity   {close_cns/1e6:>14,.6f} AUSD")
print("      " + "-" * 37)
bps = delta / clip * 10_000
print(f"      net              {delta/1e6:>+14,.6f} AUSD   ({bps:+.1f} bp on a {clip/1e6:,.0f} AUSD clip)")
print()
print("      That is the basis the entry banked, less what the unwind cost.")
print("      Both legs moved in one transaction each; neither could half-fill.")
PY
printf '\n'
