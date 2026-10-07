// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BasisTrader} from "../src/BasisTrader.sol";
import {Mainnet} from "../test/Addresses.sol";

/// @notice Deploys the trader for the MON hedge: opens its Perpl account with
///         all of `ausdSeedCNS` and registers perp 10 only.
///
/// The broadcasting account (`--account`) becomes the owner and pays the AUSD.
/// Usage: forge script script/DeployHedge.s.sol --sig 'run(address,uint256)' <keeper> <ausdSeedCNS>
contract DeployHedge is Script {
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
                leverageHdths: 200,
                maxNegPnlCollatBps: 1000,
                // `enter` is not used for the hedge; one lot of MON on a
                // 3,700 MON clip is 270 ppm.
                maxHedgeDriftPpm: 2_000,
                minEntryEdgePpm: 0,
                minExitEdgePpm: 0,
                minCashPegPpm: 999_500,
                maxCashPegPpm: 1_000_500
            })
        );

        vm.stopBroadcast();

        console2.log("BasisTrader", address(trader));
        console2.log("owner", owner);
        console2.log("perplAccountId", trader.perplAccountId());
    }
}
