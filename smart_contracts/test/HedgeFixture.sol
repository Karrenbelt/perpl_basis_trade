// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkFixture} from "./Fixtures.sol";
import {Mainnet} from "./Addresses.sol";
import {BasisTrader} from "../src/BasisTrader.sol";
import {IPerplExchange, OrderDesc, PerpetualInfoV2} from "../src/interfaces/IPerplExchange.sol";

/// @notice A `BasisTrader` with an open Perpl account and the MON market, on
///         a fork pinned to one block, and the orders the hedge tests need.
/// @dev Request IDs are the block number after a `vm.roll`, the rule the
///      mainnet commands use.
abstract contract HedgeFixture is ForkFixture {
    uint256 internal constant PROBE_BLOCK = 111_320_383;

    /// MON perp lot decimals are 0, so one lot is one MON.
    uint256 internal constant LOTS = 3_700;
    uint256 internal constant AUSD_SEED = 110e6;

    /// The price bound `DeployHedge` sets on the MON market.
    uint16 internal constant MAX_DISCOUNT_BPS = 50;
    uint32 internal constant MAX_ORACLE_AGE_SEC = 60;

    uint8 internal constant OPEN_LONG = 0;
    uint8 internal constant OPEN_SHORT = 1;
    uint8 internal constant CANCEL = 4;

    IPerplExchange internal perpl = IPerplExchange(Mainnet.PERPL_EXCHANGE);
    BasisTrader internal trader;
    uint256 internal accountId;

    function _setUpTrader() internal {
        _forkMonadAt(PROBE_BLOCK);

        trader = new BasisTrader(Mainnet.AUSD, Mainnet.PERPL_EXCHANGE, Mainnet.KURU_ROUTER, address(this));
        _fundAusd(address(this), AUSD_SEED);
        IERC20(Mainnet.AUSD).approve(address(trader), AUSD_SEED);
        trader.fund(Mainnet.AUSD, AUSD_SEED);
        accountId = trader.openPerplAccount(AUSD_SEED);
        trader.setMarket(Mainnet.PERP_MON, _monMarket(0));
        trader.setHedgeBound(Mainnet.PERP_MON, MAX_DISCOUNT_BPS, MAX_ORACLE_AGE_SEC);
    }

    function _monMarket(int64 minExitEdgePpm) internal pure returns (BasisTrader.Market memory) {
        return BasisTrader.Market({
            enabled: true,
            spotToken: address(0),
            cashToken: Mainnet.USDC,
            spotDecimals: 18,
            priceDecimals: 0, // overwritten by setMarket from the exchange
            lotDecimals: 0, // overwritten by setMarket from the exchange
            leverageHdths: 200,
            maxNegPnlCollatBps: 1000,
            maxHedgeDriftPpm: 2_000,
            minEntryEdgePpm: 0,
            minExitEdgePpm: minExitEdgePpm,
            minCashPegPpm: 999_500,
            maxCashPegPpm: 1_000_500
        });
    }

    function _nextDescId() internal returns (uint256) {
        vm.roll(vm.getBlockNumber() + 1);
        return vm.getBlockNumber();
    }

    /// One tick under the best ask, so the order is alone at the touch and a
    /// taker at its price fills it and nothing else.
    function _insideAsk() internal view returns (uint256) {
        PerpetualInfoV2 memory info = perpl.getPerpetualInfoV2(Mainnet.PERP_MON);
        return info.minAskPriceONS - info.maxBidPriceONS > 1 ? info.minAskPriceONS - 1 : info.minAskPriceONS;
    }

    function _order(
        uint8 orderType,
        uint256 orderId,
        uint256 pricePNS,
        uint256 lots,
        bool postOnly,
        bool immediate,
        uint256 descId
    ) internal pure returns (OrderDesc memory) {
        return OrderDesc({
            orderDescId: descId,
            perpId: Mainnet.PERP_MON,
            orderType: orderType,
            orderId: orderId,
            pricePNS: pricePNS,
            lotLNS: lots,
            expiryBlock: 0,
            postOnly: postOnly,
            fillOrKill: immediate,
            immediateOrCancel: immediate,
            maxMatches: immediate ? 100 : 0,
            leverageHdths: 200,
            lastExecutionBlock: 0,
            amountCNS: 0,
            maxNegPnlCollatBPS: 1000
        });
    }

    /// A second account buys `LOTS` at `pricePNS`, fill-or-kill.
    function _takeAsk(uint256 pricePNS) internal {
        _takeAsk(pricePNS, LOTS);
    }

    function _takeAsk(uint256 pricePNS, uint256 lots) internal {
        address taker = makeAddr("perplTaker");
        _fundAusd(taker, 1_000e6);
        OrderDesc memory d = _order(OPEN_LONG, 0, pricePNS, lots, false, true, _nextDescId());

        vm.startPrank(taker);
        IERC20(Mainnet.AUSD).approve(Mainnet.PERPL_EXCHANGE, 1_000e6);
        perpl.createAccount(1_000e6);
        perpl.execOrder(d);
        vm.stopPrank();
    }

    /// Sells the whole MON balance on Kuru, native MON sent with the swap.
    function _exitParams() internal returns (BasisTrader.ExitParams memory) {
        address[] memory route = new address[](1);
        route[0] = Mainnet.BOOK_MON_USDC;
        bool[] memory isBuy = new bool[](1);
        bool[] memory nativeSend = new bool[](1);
        nativeSend[0] = true;

        PerpetualInfoV2 memory info = perpl.getPerpetualInfoV2(Mainnet.PERP_MON);
        return BasisTrader.ExitParams({
            perpId: Mainnet.PERP_MON,
            assetIn: 0,
            cashPegPpm: 1_000_000,
            route: route,
            isBuy: isBuy,
            nativeSend: nativeSend,
            minCashOut: 0,
            perplLimitPricePNS: info.minAskPriceONS * 10_050 / 10_000,
            maxMatches: 100,
            requestId: _nextDescId()
        });
    }
}
