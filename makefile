SC := smart_contracts
EX := executor

# Formatting toolchain, pinned to match dex-sdk so the two repos format alike.
NIGHTLY := nightly-2026-08-22

# Tests fork Monad mainnet. Point this at a freshly started anvil to iterate
# without hammering the public RPC - but not at one `make demo` has traded
# against, or the suite inherits its drained books.
MONAD_RPC_URL ?= https://rpc.monad.xyz
export MONAD_RPC_URL

# Solidity dependencies, pinned. Vendored into smart_contracts/lib rather than
# tracked as submodules, and gitignored - `make deps` is what reconstitutes them
# on a fresh clone.
FORGE_STD := foundry-rs/forge-std@v1.17.0
OZ := OpenZeppelin/openzeppelin-contracts@v5.1.0

.PHONY: all deps build check fmt fmt-check lint test clean demo fork \
        build-sc build-ex fmt-sc fmt-ex lint-sc lint-ex test-sc test-ex


all: fmt lint build test


# ---------------------------------------------------------------- build

# Fetch the Solidity dependencies. Run once on a fresh clone.
deps:
	cd $(SC) && forge install $(FORGE_STD) --no-git
	cd $(SC) && forge install $(OZ) --no-git

# The executor generates its bindings from the Foundry artifact, so the
# contracts have to be compiled before it will build at all.
build: build-sc build-ex

build-sc:
	@test -d $(SC)/lib/forge-std || { echo "missing deps - run 'make deps'"; exit 1; }
	cd $(SC) && forge build

build-ex: build-sc
	cd $(EX) && cargo build

check: build-sc
	cd $(EX) && cargo check


# ---------------------------------------------------------------- format

fmt: fmt-sc fmt-ex

fmt-sc:
	cd $(SC) && forge fmt

fmt-ex:
	cd $(EX) && cargo +$(NIGHTLY) fmt

# What CI runs: fails rather than rewrites.
fmt-check:
	cd $(SC) && forge fmt --check
	cd $(EX) && cargo +$(NIGHTLY) fmt --check


# ---------------------------------------------------------------- lint

lint: lint-sc lint-ex

lint-sc:
	cd $(SC) && forge lint src/ test/ script/

lint-ex: build-sc
	cd $(EX) && cargo clippy --all-targets -- -D warnings


# ---------------------------------------------------------------- test

test: test-sc test-ex

test-sc:
	cd $(SC) && forge test -vv

test-ex: build-sc
	cd $(EX) && cargo test


# ---------------------------------------------------------------- local chain

# Start a Monad mainnet fork on :8545 and leave it running.
fork:
	pkill -f "anvil --fork-url" 2>/dev/null || true
	anvil --fork-url https://rpc.monad.xyz --port 8545 --chain-id 143

# A full round trip against a fresh fork: deploy, manufacture a dislocation,
# enter, let the basis converge, unwind, and report what it made.
demo:
	./scripts/demo.sh


clean:
	cd $(SC) && forge clean
	cd $(EX) && cargo clean
