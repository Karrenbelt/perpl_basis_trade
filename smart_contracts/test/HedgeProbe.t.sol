// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HedgeFixture} from "./HedgeFixture.sol";
import {Mainnet} from "./Addresses.sol";
import {BasisTrader} from "../src/BasisTrader.sol";
import {
    OrderDesc,
    OrderSignature,
    OrderV2,
    OrderLock,
    PerpetualInfoV2,
    PositionInfoV2
} from "../src/interfaces/IPerplExchange.sol";
import {IKuruOrderBook} from "../src/interfaces/IKuru.sol";

/// @notice Whether a contract's Perpl account can rest a post-only short on
///         MON, cancel it and be filled as maker; and whether `BasisTrader`
///         can unwind a MON short through a Kuru book whose base is native MON.
/// @dev Perpl is called as the trader contract through `vm.prank`, so the
///      probe needs no change to `BasisTrader`.
contract HedgeProbeTest is HedgeFixture {
    function setUp() public {
        _setUpTrader();
    }

    // ----------------------------------------------------------------
    // Gates
    // ----------------------------------------------------------------

    function test_p1_postOnlyShortRests() public {
        uint256 lockedBefore = trader.perplAccount().lockedBalanceCNS;
        uint256 price = _insideAsk();

        uint256 id = _postShort(price, _nextDescId());

        assertGt(id, 0, "execOrder returned an order id");
        OrderV2 memory o = perpl.getOrderV2(Mainnet.PERP_MON, id);
        assertEq(o.accountId, accountId, "order belongs to the trader's account");
        assertEq(o.orderType, OPEN_SHORT, "open short");
        assertEq(o.lotLNS, LOTS, "full size rests");
        assertEq(o.priceONS, price, "at the posted price");
        assertEq(o.orderId, id, "id read back equals id returned");

        OrderLock[] memory locks = perpl.getPerpOrderLocks(accountId, Mainnet.PERP_MON);
        console2.log(
            "P1 lockedBalanceCNS before", lockedBefore, "after", trader.perplAccount().lockedBalanceCNS
        );
        console2.log(
            "P1 order locks", locks.length, "first lock amountCNS", locks.length > 0 ? locks[0].amountCNS : 0
        );
    }

    function test_p2_cancelRemovesOrder() public {
        uint256 lockedBefore = trader.perplAccount().lockedBalanceCNS;
        uint256 id = _postShort(_insideAsk(), _nextDescId());

        _cancel(id, _nextDescId());

        _logOrderSlot("P2 slot after cancel", id);
        assertFalse(_isOurs(id), "no order of ours at that id");
        assertEq(perpl.getPerpOrderLocks(accountId, Mainnet.PERP_MON).length, 0, "no order lock left");
        assertEq(trader.perplAccount().lockedBalanceCNS, lockedBefore, "locked balance released");
    }

    function test_p4_makerFillFromContract() public {
        uint256 price = _insideAsk();
        uint256 id = _postShort(price, _nextDescId());

        _takeAsk(price);

        (PositionInfoV2 memory pos,,) = trader.position(Mainnet.PERP_MON);
        assertEq(pos.positionType, 1, "short");
        assertEq(pos.lotLNS, LOTS, "filled in full as maker");
        _logOrderSlot("P4 slot after fill", id);
        assertFalse(_isOurs(id), "no order of ours left at that id");
    }

    function test_p5_forceExitSellsNativeMon() public {
        uint256 price = _insideAsk();
        _postShort(price, _nextDescId());
        _takeAsk(price);

        vm.deal(address(trader), LOTS * 1e18);
        uint256 usdcBefore = IERC20(Mainnet.USDC).balanceOf(address(trader));
        (uint256 kuruBid,) = IKuruOrderBook(Mainnet.BOOK_MON_USDC).bestBidAsk();

        BasisTrader.Fill memory fill = trader.forceExit(_exitParams());

        (PositionInfoV2 memory pos,,) = trader.position(Mainnet.PERP_MON);
        assertEq(pos.lotLNS, 0, "short closed");
        assertLt(address(trader).balance, 1e18, "MON sold");
        uint256 usdcOut = IERC20(Mainnet.USDC).balanceOf(address(trader)) - usdcBefore;
        assertGt(usdcOut, 0, "USDC received");

        // Both prices in Kuru's 1e18 scale: USDC (6 dp) per MON (18 dp).
        uint256 realised = usdcOut * 1e12 / LOTS;
        console2.log("P5 Kuru bid", kuruBid, "realised", realised);
        console2.log("P5 realised against bid, bps");
        console2.logInt((int256(realised) - int256(kuruBid)) * 10_000 / int256(kuruBid));
        console2.log("P5 exit edge ppm");
        console2.logInt(fill.edgePpm);
    }

    // ----------------------------------------------------------------
    // Observations
    // ----------------------------------------------------------------

    function test_p3_crossingPostOnly() public {
        PerpetualInfoV2 memory info = perpl.getPerpetualInfoV2(Mainnet.PERP_MON);
        OrderDesc memory d = _order(OPEN_SHORT, 0, info.maxBidPriceONS, LOTS, true, false, _nextDescId());

        vm.recordLogs();
        vm.prank(address(trader));
        try perpl.execOrder(d) returns (OrderSignature memory sig) {
            console2.log("P3 no revert; returned orderId", sig.orderId);
        } catch (bytes memory reason) {
            console2.log("P3 reverted");
            console2.logBytes(reason);
        }
        _logPerplEvents("P3");

        (PositionInfoV2 memory pos,,) = trader.position(Mainnet.PERP_MON);
        assertEq(pos.lotLNS, 0, "no position");
        assertEq(perpl.getPerpOrderLocks(accountId, Mainnet.PERP_MON).length, 0, "no resting order");
    }

    /// @dev `OrderDescIdTooLow` exists in the ABI, but a direct `execOrder`
    ///      with a lower `orderDescId` is accepted; the monotonic check does
    ///      not guard this path.
    function test_p6_staleDescIdIsAccepted() public {
        uint256 first = _nextDescId();
        uint256 id = _postShort(_insideAsk(), first);
        PerpetualInfoV2 memory info = perpl.getPerpetualInfoV2(Mainnet.PERP_MON);
        // Small enough that the free balance left by the first order covers
        // it, so only the request ID can stop it.
        OrderDesc memory d = _order(OPEN_SHORT, 0, info.maxAskPriceONS, 100, true, false, first - 1);

        vm.recordLogs();
        vm.prank(address(trader));
        try perpl.execOrder(d) returns (OrderSignature memory sig) {
            console2.log("P6 no revert; returned orderId", sig.orderId);
        } catch (bytes memory reason) {
            console2.log("P6 reverted");
            console2.logBytes(reason);
        }
        _logPerplEvents("P6");

        assertTrue(_isOurs(id), "first order still rests");
        assertEq(
            perpl.getPerpOrderLocks(accountId, Mainnet.PERP_MON).length,
            2,
            "stale post rests beside the first"
        );
    }

    // ----------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------

    function _postShort(uint256 pricePNS, uint256 descId) internal returns (uint256) {
        OrderDesc memory d = _order(OPEN_SHORT, 0, pricePNS, LOTS, true, false, descId);
        vm.prank(address(trader));
        return perpl.execOrder(d).orderId;
    }

    function _cancel(uint256 orderId, uint256 descId) internal {
        OrderDesc memory d = _order(CANCEL, orderId, 0, 0, false, false, descId);
        vm.prank(address(trader));
        perpl.execOrder(d);
    }

    function _isOurs(uint256 orderId) internal view returns (bool) {
        try perpl.getOrderV2(Mainnet.PERP_MON, orderId) returns (OrderV2 memory o) {
            return o.accountId == accountId && o.lotLNS != 0;
        } catch {
            return false;
        }
    }

    function _logOrderSlot(string memory label, uint256 orderId) internal view {
        try perpl.getOrderV2(Mainnet.PERP_MON, orderId) returns (OrderV2 memory o) {
            console2.log(label);
            console2.log("  accountId", o.accountId, "lotLNS", o.lotLNS);
        } catch (bytes memory reason) {
            console2.log(label, "getOrderV2 reverted");
            console2.logBytes(reason);
        }
    }

    function _logPerplEvents(string memory label) internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != Mainnet.PERPL_EXCHANGE) continue;
            bytes32 t = logs[i].topics[0];
            string memory name = t == keccak256("CrossesBook(uint256,bool)")
                ? "CrossesBook"
                : t == keccak256("OrderPostFailed(uint256)")
                    ? "OrderPostFailed"
                    : t == keccak256("OrderDescIdTooLow(uint256)")
                        ? "OrderDescIdTooLow"
                        : t == keccak256("OrderPlaced(uint256,uint256,uint256,int256,uint256)")
                            ? "OrderPlaced"
                            : t
                                == keccak256(
                                    "OrderRequestV2(uint256,uint256,uint256,uint256,uint8,uint256,uint256,uint256,bool,bool,bool,uint256,uint256,uint256,uint256,uint256,uint256,bytes)"
                                )
                                ? "OrderRequestV2"
                                : "other";
            console2.log(label, "event", name);
            console2.logBytes32(t);
        }
    }
}
