// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BasisTrader} from "../src/BasisTrader.sol";
import {Mainnet} from "../test/Addresses.sol";

/// @notice Deploys the trader for the MON hedge: opens its Perpl account with
///         all of `ausdSeedCNS`, registers perp 10 only, and bounds its hedge
///         price against Perpl's oracle.
///
/// The broadcasting account (`--account`) becomes the owner and pays the AUSD.
/// Usage: forge script script/DeployHedge.s.sol --sig 'run(address,uint256)' <keeper> <ausdSeedCNS>
contract DeployHedge is Script {
    /// The age equals Perpl's own `refPriceMaxAgeSec` on perp 10.
    uint16 internal constant HEDGE_MAX_DISCOUNT_BPS = 50;
    uint32 internal constant HEDGE_MAX_ORACLE_AGE_SEC = 60;

    /// @param ausdSeedCNS AUSD in 6 dp. All of it opens the Perpl account, so
    ///        the contract keeps none and `hedge` runs with `marginCNS` 0.
    function run(address keeper, uint256 ausdSeedCNS) external returns (BasisTrader trader) {
        vm.startBroadcast();
        (, address owner,) = vm.readCallers();

        trader = new BasisTrader(Mainnet.AUSD, Mainnet.PERPL_EXCHANGE, Mainnet.KURU_ROUTER, owner);
        trader.setKeeper(keeper, true);
        IERC20(Mainnet.AUSD).approve(address(trader), ausdSeedCNS);
        trader.fund(Mainnet.AUSD, ausdSeedCNS);
        trader.openPerplAccount(ausdSeedCNS);
        trader.setMarket(
            Mainnet.PERP_MON,
            BasisTrader.Market({
                enabled: true,
                spotToken: address(0),
                cashToken: Mainnet.USDC,
                spotDecimals: 18,
                priceDecimals: 0, // overwritten by setMarket from the exchange
                lotDecimals: 0, // overwritten by setMarket from the exchange
                leverageHdths: 100,
                maxNegPnlCollatBps: 1000,
                // `enter` is not used for the hedge; one lot of MON on a
                // 1,850 MON clip is 540 ppm.
                maxHedgeDriftPpm: 2_000,
                // No edge reaches it, so the keeper cannot `enter` with the
                // proceeds of an exit.
                minEntryEdgePpm: type(int64).max,
                minExitEdgePpm: 0,
                // A band of zero width leaves the keeper no peg with which to
                // shade the exit gate; the owner widens it with `setMarket` if
                // AUSD leaves par.
                minCashPegPpm: 1_000_000,
                maxCashPegPpm: 1_000_000
            })
        );
        trader.setHedgeBound(Mainnet.PERP_MON, HEDGE_MAX_DISCOUNT_BPS, HEDGE_MAX_ORACLE_AGE_SEC);

        vm.stopBroadcast();

        console2.log("BasisTrader", address(trader));
        console2.log("owner", owner);
        console2.log("perplAccountId", trader.perplAccountId());
    }
}
