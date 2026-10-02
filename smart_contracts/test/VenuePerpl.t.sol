// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForkFixture} from "./Fixtures.sol";
import {Mainnet} from "./Addresses.sol";
import {
    IPerplExchange,
    OrderDesc,
    PerpetualInfoV2,
    PositionInfoV2
} from "../src/interfaces/IPerplExchange.sol";

/// @notice Pins down Perpl's own conventions against the live contract:
/// position enum values, the scale of an entry price, and that a fill-or-kill
/// taker short reaches the book at all.
contract VenuePerplTest is ForkFixture {
    IPerplExchange perpl = IPerplExchange(Mainnet.PERPL_EXCHANGE);

    function setUp() public {
        _forkMonad();
    }

    function test_shortBtcIoc() public {
        _fundAusd(address(this), 50_000e6);
        IERC20(Mainnet.AUSD).approve(Mainnet.PERPL_EXCHANGE, 50_000e6);
        uint256 accountId = perpl.createAccount(50_000e6);

        PerpetualInfoV2 memory info = perpl.getPerpetualInfoV2(Mainnet.PERP_BTC);
        console2.log("bestBid(maxBidPriceONS)", info.maxBidPriceONS, "mark", info.markPNS);

        // 0.002 BTC at lotDecimals 5.
        uint256 lots = 200;
        uint256 limit = info.maxBidPriceONS - 50; // cross a few ticks down

        perpl.execOrder(
            OrderDesc({
                orderDescId: 1,
                perpId: Mainnet.PERP_BTC,
                orderType: 1, // OpenShort
                orderId: 0,
                pricePNS: limit,
                lotLNS: lots,
                expiryBlock: 0,
                postOnly: false,
                fillOrKill: true,
                immediateOrCancel: true,
                maxMatches: 50,
                leverageHdths: 200,
                lastExecutionBlock: 0,
                amountCNS: 2_000e6,
                maxNegPnlCollatBPS: 1000
            })
        );

        (PositionInfoV2 memory pos, uint256 mark, bool valid) =
            perpl.getPositionV2(Mainnet.PERP_BTC, accountId);
        console2.log("positionType", pos.positionType, "lotLNS", pos.lotLNS);
        console2.log("entry pricePNS", pos.pricePNS, "residueQ16", pos.priceResiduePNSQ16);
        console2.log("depositCNS", pos.depositCNS, "mark", mark);
        valid;
        assertEq(pos.lotLNS, lots, "short filled in full");
        assertEq(pos.positionType, 1, "is short");
    }

    function test_bookShape() public view {
        PerpetualInfoV2 memory i = perpl.getPerpetualInfoV2(Mainnet.PERP_BTC);
        console2.log("BTC maxBid", i.maxBidPriceONS, "minBid", i.minBidPriceONS);
        console2.log("BTC maxAsk", i.maxAskPriceONS, "minAsk", i.minAskPriceONS);
        console2.log("BTC numOrders", i.numOrders, "mark", i.markPNS);
        PerpetualInfoV2 memory e = perpl.getPerpetualInfoV2(Mainnet.PERP_ETH);
        console2.log("ETH maxBid", e.maxBidPriceONS, "minAsk", e.minAskPriceONS);
        console2.log("ETH priceDec", e.priceDecimals, "lotDec", e.lotDecimals);
        PerpetualInfoV2 memory m = perpl.getPerpetualInfoV2(Mainnet.PERP_MON);
        console2.log("MON maxBid", m.maxBidPriceONS, "minAsk", m.minAskPriceONS);
        console2.log("MON priceDec", m.priceDecimals, "lotDec", m.lotDecimals);
    }
}
