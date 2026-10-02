// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BasisTrader} from "../src/BasisTrader.sol";
import {Mainnet} from "../test/Addresses.sol";

/// @notice Deploys the trader, opens its Perpl account and registers the three
///         markets where a Kuru spot book and a Perpl perpetual both exist.
///
/// Env:
///   PRIVATE_KEY      deployer, becomes owner
///   KEEPER           address allowed to call enter/exit
///   AUSD_SEED        AUSD to seed the Perpl account with (6dp)
///   USDC_SEED        USDC working capital for the spot leg (6dp)
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address keeper = vm.envAddress("KEEPER");
        uint256 ausdSeed = vm.envOr("AUSD_SEED", uint256(1_000e6));
        uint256 usdcSeed = vm.envOr("USDC_SEED", uint256(1_000e6));
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        BasisTrader trader =
            new BasisTrader(Mainnet.AUSD, Mainnet.PERPL_EXCHANGE, Mainnet.KURU_ROUTER, deployer);
        trader.setKeeper(keeper, true);

        IERC20(Mainnet.AUSD).approve(address(trader), ausdSeed);
        trader.fund(Mainnet.AUSD, ausdSeed);
        IERC20(Mainnet.USDC).approve(address(trader), usdcSeed);
        trader.fund(Mainnet.USDC, usdcSeed);

        trader.openPerplAccount(ausdSeed / 2);

        // The hedge can only be sized in whole lots, so the dust left unhedged
        // is bounded by one lot against the clip. At a 300-unit clip that is
        // ~0.29% on BTC (1e-5 BTC), ~0.91% on ETH (1e-3 ETH) and ~0.01% on MON
        // (1 MON). The bound has to leave room for that or every entry reverts;
        // tighten it when the clip grows.
        trader.setMarket(Mainnet.PERP_BTC, _market(Mainnet.CBBTC, 8, 5_000));
        trader.setMarket(Mainnet.PERP_ETH, _market(Mainnet.WETH, 18, 12_000));
        trader.setMarket(Mainnet.PERP_MON, _market(address(0), 18, 2_000));

        vm.stopBroadcast();

        console2.log("BasisTrader", address(trader));
        console2.log("perplAccountId", trader.perplAccountId());
    }

    /// @dev `priceDecimals`/`lotDecimals` are placeholders - `setMarket` reads
    ///      the real ones off the exchange and overwrites them.
    function _market(address spotToken, uint8 spotDecimals, uint32 maxHedgeDriftPpm)
        internal
        pure
        returns (BasisTrader.Market memory)
    {
        return BasisTrader.Market({
            enabled: true,
            spotToken: spotToken,
            cashToken: Mainnet.USDC,
            spotDecimals: spotDecimals,
            priceDecimals: 0,
            lotDecimals: 0,
            leverageHdths: 200,
            maxNegPnlCollatBps: 1000,
            maxHedgeDriftPpm: maxHedgeDriftPpm,
            minEntryEdgePpm: 0,
            // Negative on purpose. The basis is banked at entry; by the time it
            // has converged the unwind is worth roughly minus the taker fee, so
            // a floor of zero would refuse every exit and strand the position
            // until someone forced it. What this floor is actually for is
            // refusing to unwind into a dislocated book, and -20bp does that
            // while leaving room for the round-trip cost.
            minExitEdgePpm: -2_000,
            minCashPegPpm: 990_000,
            maxCashPegPpm: 1_010_000
        });
    }
}
