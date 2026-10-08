// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {HedgeFixture} from "./HedgeFixture.sol";
import {Mainnet} from "./Addresses.sol";
import {BasisTrader} from "../src/BasisTrader.sol";
import {
    IPerplExchange,
    OrderDesc,
    OrderSignature,
    OrderV2,
    PerpetualInfoV2,
    PositionInfoV2
} from "../src/interfaces/IPerplExchange.sol";
import {IKuruOrderBook} from "../src/interfaces/IKuru.sol";
import {DeployHedge} from "../script/DeployHedge.s.sol";

contract HedgeTest is HedgeFixture {
    address internal keeper = makeAddr("keeper");
    address internal outsider = makeAddr("outsider");

    bytes32 internal constant ORDER_REQUEST_V2 = keccak256(
        "OrderRequestV2(uint256,uint256,uint256,uint256,uint8,uint256,uint256,uint256,bool,bool,bool,uint256,uint256,uint256,uint256,uint256,uint256,bytes)"
    );

    function setUp() public {
        _setUpTrader();
        trader.setKeeper(keeper, true);
        vm.deal(address(trader), LOTS * 1e18);
    }

    function test_hedgePostsAndRecords() public {
        uint256 price = _insideAsk();
        BasisTrader.HedgeParams memory p = _hedgeParams(LOTS, price);

        vm.expectEmit(true, true, false, false, address(trader));
        emit BasisTrader.HedgePosted(Mainnet.PERP_MON, p.requestId, 0, 0, 0);
        vm.prank(keeper);
        uint256 id = trader.hedge(p);

        assertEq(trader.restingHedge(Mainnet.PERP_MON), id, "recorded");
        OrderV2 memory o = perpl.getOrderV2(Mainnet.PERP_MON, id);
        assertEq(o.accountId, accountId, "ours");
        assertEq(o.lotLNS, LOTS, "size");
        assertEq(o.priceONS, price, "price");
    }

    function test_hedgeRefusesMoreThanHeldMinusShort() public {
        uint256 price = _insideAsk();
        _hedge(LOTS, price);
        _takeAsk(price);
        _cancelHedge();

        // Short 3,700 against 3,700 MON held: one more lot is unhedged.
        BasisTrader.HedgeParams memory p = _hedgeParams(1, _insideAsk());
        vm.expectPartialRevert(BasisTrader.Unhedgeable.selector);
        vm.prank(keeper);
        trader.hedge(p);
    }

    function test_hedgeRefusesSecondWhileOneRests() public {
        uint256 id = _hedge(LOTS / 2, _insideAsk());

        BasisTrader.HedgeParams memory p = _hedgeParams(LOTS / 2, _insideAsk());
        vm.expectRevert(abi.encodeWithSelector(BasisTrader.HedgeResting.selector, Mainnet.PERP_MON, id));
        vm.prank(keeper);
        trader.hedge(p);
    }

    function test_cancelHedgeRemovesOrder() public {
        uint256 lockedBefore = trader.perplAccount().lockedBalanceCNS;
        uint256 id = _hedge(LOTS, _insideAsk());

        uint256 unfilled = _cancelHedge();

        assertEq(unfilled, LOTS, "nothing had filled");
        assertEq(trader.restingHedge(Mainnet.PERP_MON), 0, "record cleared");
        assertTrue(perpl.getOrderV2(Mainnet.PERP_MON, id).accountId != accountId, "order gone");
        assertEq(perpl.getPerpOrderLocks(accountId, Mainnet.PERP_MON).length, 0, "no lock left");
        assertEq(trader.perplAccount().lockedBalanceCNS, lockedBefore, "locked balance released");
    }

    function test_exitBlockedWhileHedgeRests() public {
        uint256 id = _hedge(LOTS, _insideAsk());
        BasisTrader.ExitParams memory x = _exitParams();

        vm.expectRevert(abi.encodeWithSelector(BasisTrader.HedgeResting.selector, Mainnet.PERP_MON, id));
        vm.prank(keeper);
        trader.exit(x);

        vm.expectRevert(abi.encodeWithSelector(BasisTrader.HedgeResting.selector, Mainnet.PERP_MON, id));
        trader.forceExit(x);
    }

    function test_filledHedgeClearsWithoutCallThenExits() public {
        uint256 price = _insideAsk();
        _hedge(LOTS, price);
        _takeAsk(price);

        vm.recordLogs();
        uint256 unfilled = _cancelHedge();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].emitter != Mainnet.PERPL_EXCHANGE || logs[i].topics[0] != ORDER_REQUEST_V2,
                "no order sent to Perpl"
            );
        }
        assertEq(unfilled, 0, "fully filled");
        assertEq(trader.restingHedge(Mainnet.PERP_MON), 0, "record cleared");

        trader.setMarket(Mainnet.PERP_MON, _monMarket(-1_000_000));
        BasisTrader.ExitParams memory x = _exitParams();
        vm.prank(keeper);
        BasisTrader.Fill memory fill = trader.exit(x);

        (PositionInfoV2 memory pos,,) = trader.position(Mainnet.PERP_MON);
        assertEq(pos.lotLNS, 0, "short closed");
        assertEq(fill.assetAmount, LOTS * 1e18, "sold the hedged MON");
        assertEq(address(trader).balance, 0, "no MON left");
    }

    /// A part fill leaves more MON than short, so the exit must be sized to
    /// the filled lots; sized to the whole balance, Perpl refuses to close
    /// more than the short.
    function test_partFillExitsOnlyTheFilledLots() public {
        uint256 filled = 1_000;
        uint256 price = _insideAsk();
        _hedge(LOTS, price);
        _takeAsk(price, filled);

        assertEq(_cancelHedge(), LOTS - filled, "unfilled rest cancelled");
        (PositionInfoV2 memory pos,,) = trader.position(Mainnet.PERP_MON);
        assertEq(pos.lotLNS, filled, "short is the filled part");

        trader.setMarket(Mainnet.PERP_MON, _monMarket(-1_000_000));
        BasisTrader.ExitParams memory whole = _exitParams();
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("CloseOrderExceedsPosition(uint256,uint256)")), filled, LOTS
            )
        );
        vm.prank(keeper);
        trader.exit(whole);

        BasisTrader.ExitParams memory part = _exitParams();
        part.assetIn = filled * 1e18;
        vm.prank(keeper);
        trader.exit(part);

        (pos,,) = trader.position(Mainnet.PERP_MON);
        assertEq(pos.lotLNS, 0, "short closed");
        assertEq(address(trader).balance, (LOTS - filled) * 1e18, "unhedged rest kept");
    }

    function test_onlyKeeperCanHedgeOrCancel() public {
        BasisTrader.HedgeParams memory p = _hedgeParams(LOTS, _insideAsk());

        vm.expectRevert(BasisTrader.NotKeeper.selector);
        vm.prank(outsider);
        trader.hedge(p);

        vm.expectRevert(BasisTrader.NotKeeper.selector);
        vm.prank(outsider);
        trader.cancelHedge(Mainnet.PERP_MON, block.number);
    }

    function test_crossingHedgeLeavesNoState() public {
        PerpetualInfoV2 memory info = perpl.getPerpetualInfoV2(Mainnet.PERP_MON);
        BasisTrader.HedgeParams memory p = _hedgeParams(LOTS, info.maxBidPriceONS);

        // Perpl's own error, not ours.
        vm.expectPartialRevert(bytes4(keccak256("CrossesBook(uint256,uint256,uint256,bool,uint256,bool)")));
        vm.prank(keeper);
        trader.hedge(p);

        assertEq(trader.restingHedge(Mainnet.PERP_MON), 0, "nothing recorded");
        (PositionInfoV2 memory pos,,) = trader.position(Mainnet.PERP_MON);
        assertEq(pos.lotLNS, 0, "no position");
    }

    /// A cancel that returns but leaves the order resting must not unblock
    /// `exit`. Perpl is mocked to do nothing for this one descriptor, because
    /// a stale request ID does not: Perpl accepts it on a direct call.
    function test_ineffectiveCancelReverts() public {
        uint256 id = _hedge(LOTS, _insideAsk());
        uint256 requestId = _nextDescId();
        OrderDesc memory cancel = OrderDesc({
            orderDescId: requestId,
            perpId: Mainnet.PERP_MON,
            orderType: CANCEL,
            orderId: id,
            pricePNS: 0,
            lotLNS: 0,
            expiryBlock: 0,
            postOnly: false,
            fillOrKill: false,
            immediateOrCancel: false,
            maxMatches: 0,
            leverageHdths: 0,
            lastExecutionBlock: 0,
            amountCNS: 0,
            maxNegPnlCollatBPS: 0
        });
        vm.mockCall(
            Mainnet.PERPL_EXCHANGE,
            abi.encodeCall(IPerplExchange.execOrder, (cancel)),
            abi.encode(OrderSignature({perpId: 0, orderId: 0}))
        );

        vm.expectRevert(abi.encodeWithSelector(BasisTrader.HedgeNotCancelled.selector, id));
        vm.prank(keeper);
        trader.cancelHedge(Mainnet.PERP_MON, requestId);
        vm.clearMockedCalls();

        assertEq(trader.restingHedge(Mainnet.PERP_MON), id, "record kept");
        assertEq(perpl.getOrderV2(Mainnet.PERP_MON, id).accountId, accountId, "order still rests");
        BasisTrader.ExitParams memory x = _exitParams();
        vm.expectRevert(abi.encodeWithSelector(BasisTrader.HedgeResting.selector, Mainnet.PERP_MON, id));
        vm.prank(keeper);
        trader.exit(x);
    }

    function test_unusableOracleReverts() public {
        uint256 price = _insideAsk();

        PerpetualInfoV2 memory info = perpl.getPerpetualInfoV2(Mainnet.PERP_MON);
        info.oraclePNS = 0;
        _expectOracleUnusable(info, price);

        info = perpl.getPerpetualInfoV2(Mainnet.PERP_MON);
        info.ignOracle = true;
        _expectOracleUnusable(info, price);
    }

    function test_hedgeUnderBoundReverts() public {
        PerpetualInfoV2 memory info = perpl.getPerpetualInfoV2(Mainnet.PERP_MON);
        uint256 floor = Math.ceilDiv(info.oraclePNS * (10_000 - MAX_DISCOUNT_BPS), 10_000);
        assertLe(floor, info.maxBidPriceONS, "precondition: a post at the floor crosses the book");

        BasisTrader.HedgeParams memory p = _hedgeParams(LOTS, floor - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                BasisTrader.HedgeBelowOracle.selector, floor - 1, info.oraclePNS, uint256(MAX_DISCOUNT_BPS)
            )
        );
        vm.prank(keeper);
        trader.hedge(p);

        // Perpl's own error shows that our check let the floor through.
        p = _hedgeParams(LOTS, floor);
        vm.expectPartialRevert(bytes4(keccak256("CrossesBook(uint256,uint256,uint256,bool,uint256,bool)")));
        vm.prank(keeper);
        trader.hedge(p);
    }

    function test_staleOracleReverts() public {
        uint256 price = _insideAsk();
        uint256 oracleTs = perpl.getPerpetualInfoV2(Mainnet.PERP_MON).oracleTimestampSec;

        vm.warp(oracleTs + MAX_ORACLE_AGE_SEC + 1);
        BasisTrader.HedgeParams memory p = _hedgeParams(LOTS, price);
        vm.expectRevert(
            abi.encodeWithSelector(BasisTrader.OracleStale.selector, oracleTs, uint256(MAX_ORACLE_AGE_SEC))
        );
        vm.prank(keeper);
        trader.hedge(p);

        vm.warp(oracleTs + MAX_ORACLE_AGE_SEC);
        p = _hedgeParams(LOTS, price);
        vm.prank(keeper);
        uint256 id = trader.hedge(p);
        assertEq(perpl.getOrderV2(Mainnet.PERP_MON, id).accountId, accountId, "rests at the age limit");
    }

    function test_hedgeRevertsWithoutBound() public {
        BasisTrader unbound =
            new BasisTrader(Mainnet.AUSD, Mainnet.PERPL_EXCHANGE, Mainnet.KURU_ROUTER, address(this));
        _fundAusd(address(this), AUSD_SEED);
        IERC20(Mainnet.AUSD).approve(address(unbound), AUSD_SEED);
        unbound.fund(Mainnet.AUSD, AUSD_SEED);
        unbound.openPerplAccount(AUSD_SEED);
        unbound.setMarket(Mainnet.PERP_MON, _monMarket(0));
        vm.deal(address(unbound), LOTS * 1e18);

        BasisTrader.HedgeParams memory p = _hedgeParams(LOTS, _insideAsk());
        vm.expectRevert(abi.encodeWithSelector(BasisTrader.HedgeBoundNotSet.selector, Mainnet.PERP_MON));
        unbound.hedge(p);
    }

    function test_onlyOwnerSetsHedgeBound() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        vm.prank(keeper);
        trader.setHedgeBound(Mainnet.PERP_MON, 0, 1);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        vm.prank(outsider);
        trader.setHedgeBound(Mainnet.PERP_MON, 0, 1);

        vm.expectEmit(true, false, false, true, address(trader));
        emit BasisTrader.HedgeBoundSet(Mainnet.PERP_MON, 75, 30);
        trader.setHedgeBound(Mainnet.PERP_MON, 75, 30);
        assertEq(trader.hedgeMaxDiscountBps(Mainnet.PERP_MON), 75, "bps");
        assertEq(trader.hedgeMaxOracleAgeSec(Mainnet.PERP_MON), 30, "age");
    }

    function test_setHedgeBoundRejectsBadValues() public {
        vm.expectRevert(BasisTrader.BadHedgeBound.selector);
        trader.setHedgeBound(Mainnet.PERP_MON, 10_000, MAX_ORACLE_AGE_SEC);

        vm.expectRevert(BasisTrader.BadHedgeBound.selector);
        trader.setHedgeBound(Mainnet.PERP_MON, MAX_DISCOUNT_BPS, 0);
    }

    /// Perpl's `increasePositionCollateral` takes no token, so where the
    /// collateral comes from is read from the balances.
    function test_topUpDrawsFromPerplBalance() public {
        uint256 price = _insideAsk();
        _hedge(LOTS, price);
        _takeAsk(price);
        _cancelHedge();
        assertEq(IERC20(Mainnet.AUSD).balanceOf(address(trader)), 0, "contract holds no AUSD");

        uint256 balanceBefore = trader.perplAccount().balanceCNS;
        (PositionInfoV2 memory before,,) = trader.position(Mainnet.PERP_MON);

        vm.prank(keeper);
        trader.topUpPosition(Mainnet.PERP_MON, 5e6);

        (PositionInfoV2 memory post,,) = trader.position(Mainnet.PERP_MON);
        assertEq(post.depositCNS, before.depositCNS + 5e6, "position collateral up");
        assertEq(trader.perplAccount().balanceCNS, balanceBefore - 5e6, "drawn from the account");
        assertEq(IERC20(Mainnet.AUSD).balanceOf(address(trader)), 0, "contract still holds no AUSD");
    }

    /// Mocks perp 10's info only, and clears it, so that no later read in
    /// the test sees the mocked oracle.
    function _expectOracleUnusable(PerpetualInfoV2 memory info, uint256 pricePNS) internal {
        BasisTrader.HedgeParams memory p = _hedgeParams(LOTS, pricePNS);
        vm.mockCall(
            Mainnet.PERPL_EXCHANGE,
            abi.encodeCall(IPerplExchange.getPerpetualInfoV2, (Mainnet.PERP_MON)),
            abi.encode(info)
        );
        vm.expectRevert(abi.encodeWithSelector(BasisTrader.OracleUnusable.selector, Mainnet.PERP_MON));
        vm.prank(keeper);
        trader.hedge(p);
        vm.clearMockedCalls();
    }

    function _hedgeParams(uint256 lots, uint256 pricePNS) internal returns (BasisTrader.HedgeParams memory) {
        return BasisTrader.HedgeParams({
            perpId: Mainnet.PERP_MON, lotLNS: lots, pricePNS: pricePNS, marginCNS: 0, requestId: _nextDescId()
        });
    }

    function _hedge(uint256 lots, uint256 pricePNS) internal returns (uint256) {
        BasisTrader.HedgeParams memory p = _hedgeParams(lots, pricePNS);
        vm.prank(keeper);
        return trader.hedge(p);
    }

    function _cancelHedge() internal returns (uint256) {
        uint256 requestId = _nextDescId();
        vm.prank(keeper);
        return trader.cancelHedge(Mainnet.PERP_MON, requestId);
    }
}

contract DeployHedgeTest is HedgeFixture {
    uint256 internal constant CLIP = 1_850;
    /// At the pinned price this buys about 750 MON, so the part of a lot left
    /// unhedged is under about 1,330 ppm and the drift check (2,000 ppm)
    /// cannot refuse before the edge gate.
    uint256 internal constant ENTER_CASH = 20e6;

    address internal keeper = makeAddr("keeper");

    function test_deployHedgeOpensAccountAndMonMarket() public {
        BasisTrader deployed = _deploy();

        assertGt(deployed.perplAccountId(), 0, "Perpl account opened");
        (
            bool enabled,,,,,,
            uint16 leverageHdths,,,
            int64 minEntryEdgePpm,
            int64 minExitEdgePpm,
            uint32 minCashPegPpm,
            uint32 maxCashPegPpm
        ) = deployed.markets(Mainnet.PERP_MON);
        assertTrue(enabled, "MON market registered");
        assertEq(leverageHdths, 100, "1x");
        assertEq(minEntryEdgePpm, type(int64).max, "enter closed");
        assertEq(minExitEdgePpm, 0, "exit floor");
        assertEq(minCashPegPpm, 1_000_000, "peg band closed, low");
        assertEq(maxCashPegPpm, 1_000_000, "peg band closed, high");
        assertEq(deployed.hedgeMaxDiscountBps(Mainnet.PERP_MON), 50, "hedge bound");
        assertEq(deployed.hedgeMaxOracleAgeSec(Mainnet.PERP_MON), 60, "oracle age");
        assertEq(deployed.owner(), DEFAULT_SENDER, "broadcaster owns it");
        assertTrue(deployed.keepers(keeper), "keeper set");
    }

    /// Clip 1 filled and held at 1x, then clip 2 resting beside it, on the
    /// AUSD the deploy seeds.
    function test_deployedInstanceHoldsTwoClips() public {
        BasisTrader deployed = _deploy();
        vm.deal(address(deployed), 2 * CLIP * 1e18);

        uint256 price = _insideAsk();
        BasisTrader.HedgeParams memory p = _clip(price);
        vm.prank(keeper);
        deployed.hedge(p);
        _takeAsk(price, CLIP);
        uint256 cancelId = _nextDescId();
        vm.prank(keeper);
        deployed.cancelHedge(Mainnet.PERP_MON, cancelId);
        (PositionInfoV2 memory pos,,) = deployed.position(Mainnet.PERP_MON);
        assertEq(pos.lotLNS, CLIP, "clip 1 held");

        p = _clip(_insideAsk());
        vm.prank(keeper);
        uint256 id = deployed.hedge(p);
        assertEq(perpl.getOrderV2(Mainnet.PERP_MON, id).accountId, deployed.perplAccountId(), "clip 2 rests");
    }

    /// Any realised edge is below the stored entry floor of `type(int64).max`.
    function test_deployedInstanceRefusesEnter() public {
        BasisTrader deployed = _deploy();
        deal(Mainnet.USDC, address(deployed), ENTER_CASH);

        address[] memory route = new address[](1);
        route[0] = Mainnet.BOOK_MON_USDC;
        bool[] memory isBuy = new bool[](1);
        isBuy[0] = true;
        bool[] memory nativeSend = new bool[](1);
        PerpetualInfoV2 memory info = perpl.getPerpetualInfoV2(Mainnet.PERP_MON);
        BasisTrader.EnterParams memory p = BasisTrader.EnterParams({
            perpId: Mainnet.PERP_MON,
            cashIn: ENTER_CASH,
            cashPegPpm: 1_000_000,
            route: route,
            isBuy: isBuy,
            nativeSend: nativeSend,
            minAssetOut: 0,
            perplLimitPricePNS: info.maxBidPriceONS * 9_900 / 10_000,
            minLotLNS: 1,
            maxLotLNS: 10_000,
            marginCNS: 0,
            maxMatches: 100,
            requestId: _nextDescId()
        });

        vm.expectPartialRevert(BasisTrader.EdgeTooThin.selector);
        vm.prank(keeper);
        deployed.enter(p);
    }

    /// With both clips' MON held, an exit sized to the balance asks Perpl to
    /// close twice the short; and the closed peg band admits only par.
    function test_deployedExitTakesClipSizeAndParPeg() public {
        BasisTrader deployed = _deployWithClip1Filled();
        BasisTrader.ExitParams memory x = _exitParams();

        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("CloseOrderExceedsPosition(uint256,uint256)")), CLIP, 2 * CLIP
            )
        );
        vm.prank(DEFAULT_SENDER);
        deployed.forceExit(x);

        x.assetIn = CLIP * 1e18;
        x.cashPegPpm = 999_999;
        vm.expectRevert(
            abi.encodeWithSelector(BasisTrader.PegOutOfBand.selector, 999_999, 1_000_000, 1_000_000)
        );
        vm.prank(DEFAULT_SENDER);
        deployed.forceExit(x);

        x.cashPegPpm = 1_000_001;
        vm.expectRevert(
            abi.encodeWithSelector(BasisTrader.PegOutOfBand.selector, 1_000_001, 1_000_000, 1_000_000)
        );
        vm.prank(DEFAULT_SENDER);
        deployed.forceExit(x);
    }

    /// The keeper's exit is gated at floor 0 on the edge the same exit
    /// realises; the owner's exit, within the stop-rule bounds, closes the
    /// clip and keeps clip 2's MON.
    function test_deployedExitGateThenForceExit() public {
        BasisTrader deployed = _deployWithClip1Filled();
        BasisTrader.ExitParams memory x = _exitParams();
        x.assetIn = CLIP * 1e18;
        // Kuru quotes USDC (6 dp) per MON (18 dp) in a 1e18 scale.
        (uint256 kuruBid,) = IKuruOrderBook(Mainnet.BOOK_MON_USDC).bestBidAsk();
        x.minCashOut = CLIP * kuruBid * 995 / (1_000 * 1e12);
        uint256 usdcBefore = IERC20(Mainnet.USDC).balanceOf(address(deployed));

        uint256 snap = vm.snapshotState();
        vm.prank(DEFAULT_SENDER);
        int256 edgePpm = deployed.forceExit(x).edgePpm;
        vm.revertToState(snap);

        BasisTrader.Fill memory fill;
        if (edgePpm < 0) {
            vm.expectRevert(abi.encodeWithSelector(BasisTrader.EdgeTooThin.selector, edgePpm, int256(0)));
            vm.prank(keeper);
            deployed.exit(x);
            vm.prank(DEFAULT_SENDER);
            fill = deployed.forceExit(x);
        } else {
            vm.prank(keeper);
            fill = deployed.exit(x);
        }

        (PositionInfoV2 memory pos,,) = deployed.position(Mainnet.PERP_MON);
        assertEq(pos.lotLNS, 0, "short closed");
        assertEq(fill.lotLNS, CLIP, "clip bought back");
        assertEq(address(deployed).balance, CLIP * 1e18, "clip 2 MON kept");
        uint256 usdcOut = IERC20(Mainnet.USDC).balanceOf(address(deployed)) - usdcBefore;
        assertEq(usdcOut, fill.spotNotionalCNS, "proceeds at par peg");
        assertGe(usdcOut, x.minCashOut, "within the stop-rule floor");
    }

    function _deployWithClip1Filled() internal returns (BasisTrader deployed) {
        deployed = _deploy();
        vm.deal(address(deployed), 2 * CLIP * 1e18);

        uint256 price = _insideAsk();
        BasisTrader.HedgeParams memory p = _clip(price);
        vm.prank(keeper);
        deployed.hedge(p);
        _takeAsk(price, CLIP);
        uint256 cancelId = _nextDescId();
        vm.prank(keeper);
        deployed.cancelHedge(Mainnet.PERP_MON, cancelId);
    }

    function _deploy() internal returns (BasisTrader) {
        _forkMonadAt(PROBE_BLOCK);
        _fundAusd(DEFAULT_SENDER, AUSD_SEED);
        return new DeployHedge().run(keeper, AUSD_SEED);
    }

    function _clip(uint256 pricePNS) internal returns (BasisTrader.HedgeParams memory) {
        return BasisTrader.HedgeParams({
            perpId: Mainnet.PERP_MON, lotLNS: CLIP, pricePNS: pricePNS, marginCNS: 0, requestId: _nextDescId()
        });
    }
}
