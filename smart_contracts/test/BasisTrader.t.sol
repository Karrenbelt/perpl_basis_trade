// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkFixture} from "./Fixtures.sol";
import {Mainnet} from "./Addresses.sol";
import {BasisTrader} from "../src/BasisTrader.sol";
import {IPerplExchange, PerpetualInfoV2, PositionInfoV2} from "../src/interfaces/IPerplExchange.sol";
import {IKuruOrderBook} from "../src/interfaces/IKuru.sol";

contract BasisTraderTest is ForkFixture {
    BasisTrader internal trader;
    IPerplExchange internal perpl = IPerplExchange(Mainnet.PERPL_EXCHANGE);

    address internal keeper = makeAddr("keeper");
    address internal outsider = makeAddr("outsider");

    /// AUSD per USDC in ppm. The AUSD/USDC book quotes AUSD around 1.0004 USDC,
    /// so a USDC is worth a shade under one AUSD.
    uint32 internal constant PEG = 999_600;

    /// Both books are thin near touch - Perpl's BTC bid holds roughly 0.004 BTC
    /// and Kuru's cbBTC ask a few thousand dollars - so the tests trade the
    /// size the venues can actually absorb rather than a round number.
    uint256 internal constant TRADE_USDC = 300e6;
    uint256 internal constant TRADE_MARGIN = 200e6;

    uint256 internal constant AUSD_CAPITAL = 50_000e6;
    uint256 internal constant USDC_CAPITAL = 10_000e6;
    uint256 internal constant PERPL_SEED = 40_000e6;

    function setUp() public {
        _forkMonad();

        trader = new BasisTrader(Mainnet.AUSD, Mainnet.PERPL_EXCHANGE, Mainnet.KURU_ROUTER, address(this));
        trader.setKeeper(keeper, true);

        _fundAusd(address(this), AUSD_CAPITAL);
        IERC20(Mainnet.AUSD).approve(address(trader), AUSD_CAPITAL);
        trader.fund(Mainnet.AUSD, AUSD_CAPITAL);

        deal(Mainnet.USDC, address(this), USDC_CAPITAL);
        IERC20(Mainnet.USDC).approve(address(trader), USDC_CAPITAL);
        trader.fund(Mainnet.USDC, USDC_CAPITAL);

        trader.openPerplAccount(PERPL_SEED);
        trader.setMarket(Mainnet.PERP_BTC, _btcMarket(0, -1_000_000));
    }

    // ----------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------

    function _btcMarket(int64 minEntryEdgePpm, int64 minExitEdgePpm)
        internal
        pure
        returns (BasisTrader.Market memory)
    {
        return BasisTrader.Market({
            enabled: true,
            spotToken: Mainnet.CBBTC,
            cashToken: Mainnet.USDC,
            spotDecimals: 8,
            priceDecimals: 0, // overwritten by setMarket from the exchange
            lotDecimals: 0, // overwritten by setMarket from the exchange
            leverageHdths: 200,
            maxNegPnlCollatBps: 1000,
            maxHedgeDriftPpm: 5_000,
            minEntryEdgePpm: minEntryEdgePpm,
            minExitEdgePpm: minExitEdgePpm,
            minCashPegPpm: 990_000,
            maxCashPegPpm: 1_010_000
        });
    }

    function _enterParams(uint256 cashIn, uint256 minAssetOut, uint256 marginCNS)
        internal
        view
        returns (BasisTrader.EnterParams memory p)
    {
        address[] memory route = new address[](1);
        route[0] = Mainnet.BOOK_CBBTC_USDC;
        bool[] memory isBuy = new bool[](1);
        isBuy[0] = true;
        bool[] memory nativeSend = new bool[](1);

        PerpetualInfoV2 memory info = perpl.getPerpetualInfoV2(Mainnet.PERP_BTC);

        p = BasisTrader.EnterParams({
            perpId: Mainnet.PERP_BTC,
            cashIn: cashIn,
            cashPegPpm: PEG,
            route: route,
            isBuy: isBuy,
            nativeSend: nativeSend,
            minAssetOut: minAssetOut,
            // Relative, not a tick count: Perpl's price decimals range from 1
            // on BTC to 6 on MON, and the book's depth at the touch varies with
            // the fork block. The edge gate is what keeps a deep reach honest.
            perplLimitPricePNS: info.maxBidPriceONS * 9_950 / 10_000,
            minLotLNS: 1,
            maxLotLNS: type(uint96).max,
            marginCNS: marginCNS,
            maxMatches: 100,
            requestId: 1
        });
    }

    function _exitParams(uint256 assetIn, uint256 minCashOut)
        internal
        view
        returns (BasisTrader.ExitParams memory p)
    {
        address[] memory route = new address[](1);
        route[0] = Mainnet.BOOK_CBBTC_USDC;
        bool[] memory isBuy = new bool[](1);
        isBuy[0] = false; // selling cbBTC, the base asset
        bool[] memory nativeSend = new bool[](1);

        PerpetualInfoV2 memory info = perpl.getPerpetualInfoV2(Mainnet.PERP_BTC);

        p = BasisTrader.ExitParams({
            perpId: Mainnet.PERP_BTC,
            assetIn: assetIn,
            cashPegPpm: PEG,
            route: route,
            isBuy: isBuy,
            nativeSend: nativeSend,
            minCashOut: minCashOut,
            perplLimitPricePNS: info.minAskPriceONS * 10_050 / 10_000,
            maxMatches: 100,
            requestId: 2
        });
    }

    /// Rest an ask cheap enough that shorting the perp against it clears the
    /// 3.45bp Perpl taker fee with room to spare.
    function _seedProfitableSpot() internal {
        _seedCheapAsk(Mainnet.BOOK_CBBTC_USDC, Mainnet.CBBTC, _ticksFromMark(9_950), uint96(1e6));
    }

    /// A Kuru price for the cbBTC book, `bps` of the perp mark.
    ///
    /// Derived from the live mark rather than hardcoded, so the tests survive
    /// the fork moving: a fixed price that was a discount at one block is a
    /// premium at another, and the assertion silently inverts.
    function _ticksFromMark(uint256 bps) internal view returns (uint32) {
        PerpetualInfoV2 memory info = perpl.getPerpetualInfoV2(Mainnet.PERP_BTC);
        (uint32 pricePrecision,,,,,, uint32 tickSize,,,,) =
            IKuruOrderBook(Mainnet.BOOK_CBBTC_USDC).getMarketParams();

        uint256 ticks = info.markPNS * pricePrecision / 10 ** info.priceDecimals;
        ticks = ticks * bps / 10_000;
        // The book only accepts prices on its own tick grid.
        ticks = ticks / tickSize * tickSize;
        assertLe(ticks, type(uint32).max, "price does not fit the book's uint32");
        // Bounded on the line above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(ticks);
    }

    // ----------------------------------------------------------------
    // Setup
    // ----------------------------------------------------------------

    function test_setupCachesPerpScales() public view {
        (,,, uint8 spotDecimals, uint8 priceDecimals, uint8 lotDecimals,,,,,,,) =
            trader.markets(Mainnet.PERP_BTC);
        assertEq(spotDecimals, 8, "cbBTC decimals");
        assertEq(priceDecimals, 1, "BTC perp priceDecimals");
        assertEq(lotDecimals, 5, "BTC perp lotDecimals");
        assertGt(trader.perplAccountId(), 0, "perpl account opened");
    }

    // ----------------------------------------------------------------
    // Enter
    // ----------------------------------------------------------------

    /// @dev Deliberately not asserted against the *live* basis. Which way the
    ///      untouched books lean changes with the fork block, and a test that
    ///      depends on that is testing the market, not the contract. An
    ///      unreachable floor makes the refusal about the gate.
    function test_enterRefusesEdgeBelowFloor() public {
        _seedProfitableSpot();
        trader.setMarket(Mainnet.PERP_BTC, _btcMarket(50_000, -1_000_000)); // demand 5%

        BasisTrader.EnterParams memory p = _enterParams(TRADE_USDC, 330_000, TRADE_MARGIN);
        vm.prank(keeper);
        vm.expectPartialRevert(BasisTrader.EdgeTooThin.selector);
        trader.enter(p);
    }

    function test_enterFillsBothLegsWhenEdgeClears() public {
        _seedProfitableSpot();

        BasisTrader.EnterParams memory p = _enterParams(TRADE_USDC, 330_000, TRADE_MARGIN);
        vm.prank(keeper);
        BasisTrader.Fill memory fill = trader.enter(p);

        console2.log("entry edge ppm");
        console2.logInt(fill.edgePpm);
        console2.log("spot CNS", fill.spotNotionalCNS, "perp CNS", fill.perpNotionalCNS);
        console2.log("asset", fill.assetAmount, "lots", fill.lotLNS);

        assertGt(fill.edgePpm, 0, "edge cleared the floor");

        // The spot notional is the hedged share of the cash, not all of it.
        uint256 cashCNS = (TRADE_USDC * uint256(PEG)) / 1e6;
        uint256 hedgedTokensForCheck = fill.lotLNS * 1e3;
        assertEq(
            fill.spotNotionalCNS,
            (cashCNS * hedgedTokensForCheck) / fill.assetAmount,
            "spot notional covers only the hedged share"
        );
        assertLe(fill.spotNotionalCNS, cashCNS, "never more than the cash spent");

        (PositionInfoV2 memory pos,,) = trader.position(Mainnet.PERP_BTC);
        assertEq(pos.positionType, 1, "short");
        assertEq(pos.lotLNS, fill.lotLNS, "hedge size on the book");

        uint256 held = IERC20(Mainnet.CBBTC).balanceOf(address(trader));
        assertEq(held, fill.assetAmount, "spot held by the contract");

        // The hedge covers the spot to within the configured dust bound.
        uint256 hedgedTokens = fill.lotLNS * 1e3; // 8 token decimals vs 5 lot decimals
        assertLe(held - hedgedTokens, (held * 5_000) / 1e6, "unhedged dust within bound");
    }

    /// A refused entry must leave nothing behind - not the spot it would have
    /// bought, not the cash it would have spent, not a naked short.
    function test_enterIsAtomicOnThinEdge() public {
        _seedProfitableSpot();
        trader.setMarket(Mainnet.PERP_BTC, _btcMarket(50_000, -1_000_000));

        uint256 usdcBefore = IERC20(Mainnet.USDC).balanceOf(address(trader));
        uint256 cbbtcBefore = IERC20(Mainnet.CBBTC).balanceOf(address(trader));

        BasisTrader.EnterParams memory p = _enterParams(TRADE_USDC, 330_000, TRADE_MARGIN);
        vm.prank(keeper);
        vm.expectPartialRevert(BasisTrader.EdgeTooThin.selector);
        trader.enter(p);

        assertEq(IERC20(Mainnet.USDC).balanceOf(address(trader)), usdcBefore, "no cash spent");
        assertEq(IERC20(Mainnet.CBBTC).balanceOf(address(trader)), cbbtcBefore, "no spot bought");
        (PositionInfoV2 memory pos,,) = trader.position(Mainnet.PERP_BTC);
        assertEq(pos.lotLNS, 0, "no perp exposure");
    }

    function test_enterRejectsOutOfBandPeg() public {
        _seedProfitableSpot();
        BasisTrader.EnterParams memory p = _enterParams(TRADE_USDC, 330_000, TRADE_MARGIN);
        p.cashPegPpm = 1_500_000; // claim a USDC is worth 1.5 AUSD
        vm.prank(keeper);
        vm.expectPartialRevert(BasisTrader.PegOutOfBand.selector);
        trader.enter(p);
    }

    function test_enterRejectsSlippedSpotFill() public {
        _seedProfitableSpot();
        BasisTrader.EnterParams memory p = _enterParams(TRADE_USDC, 10e8, TRADE_MARGIN); // demand 10 cbBTC
        vm.prank(keeper);
        vm.expectRevert();
        trader.enter(p);
    }

    function test_enterRejectsLotsOutOfBand() public {
        _seedProfitableSpot();
        BasisTrader.EnterParams memory p = _enterParams(TRADE_USDC, 330_000, TRADE_MARGIN);
        p.maxLotLNS = 10; // far under what 1,000 USDC of cbBTC rounds to
        vm.prank(keeper);
        vm.expectPartialRevert(BasisTrader.LotsOutOfBand.selector);
        trader.enter(p);
    }

    function test_onlyKeeperCanEnter() public {
        BasisTrader.EnterParams memory p = _enterParams(TRADE_USDC, 300_000, TRADE_MARGIN);
        vm.prank(outsider);
        vm.expectRevert(BasisTrader.NotKeeper.selector);
        trader.enter(p);
    }

    // ----------------------------------------------------------------
    // Exit
    // ----------------------------------------------------------------

    function _openPosition() internal returns (BasisTrader.Fill memory) {
        _seedProfitableSpot();
        BasisTrader.EnterParams memory p = _enterParams(TRADE_USDC, 330_000, TRADE_MARGIN);
        vm.prank(keeper);
        return trader.enter(p);
    }

    function test_exitUnwindsBothLegs() public {
        BasisTrader.Fill memory entry = _openPosition();

        // Seeding the entry walked the bid out of the way, so without putting
        // one back the unwind sells into an empty book and the test measures
        // nothing but that. This bid is below break-even on purpose - the
        // point here is that both legs come off, not that the unwind pays.
        _seedRichBid(Mainnet.BOOK_CBBTC_USDC, Mainnet.USDC, _ticksFromMark(9_900), uint96(1e6));

        BasisTrader.ExitParams memory x = _exitParams(0, 0);
        vm.prank(keeper);
        BasisTrader.Fill memory fill = trader.exit(x);

        console2.log("exit edge ppm");
        console2.logInt(fill.edgePpm);
        console2.log("round trip ppm");
        console2.logInt(entry.edgePpm + fill.edgePpm);

        (PositionInfoV2 memory pos,,) = trader.position(Mainnet.PERP_BTC);
        assertEq(pos.lotLNS, 0, "short fully closed");
        assertLe(IERC20(Mainnet.CBBTC).balanceOf(address(trader)), 1e3, "spot sold down to dust");
    }

    function test_exitClearsFloorWhenSpotIsRich() public {
        _openPosition();
        trader.setMarket(Mainnet.PERP_BTC, _btcMarket(0, 0)); // demand a non-negative unwind

        // The spot sale has to beat the perp buy-back plus the 3.45bp taker fee
        // for the gate to let the unwind through.
        _seedRichBid(Mainnet.BOOK_CBBTC_USDC, Mainnet.USDC, _ticksFromMark(10_050), uint96(1e6));

        BasisTrader.ExitParams memory x = _exitParams(0, 0);
        vm.prank(keeper);
        BasisTrader.Fill memory fill = trader.exit(x);

        console2.log("rich exit edge ppm");
        console2.logInt(fill.edgePpm);
        assertGt(fill.edgePpm, 0, "exit edge cleared the floor");

        (PositionInfoV2 memory pos,,) = trader.position(Mainnet.PERP_BTC);
        assertEq(pos.lotLNS, 0, "short fully closed");
    }

    function test_exitRefusesBelowFloor() public {
        _openPosition();
        trader.setMarket(Mainnet.PERP_BTC, _btcMarket(0, 100_000)); // demand 10% on the way out

        BasisTrader.ExitParams memory x = _exitParams(0, 0);
        vm.prank(keeper);
        vm.expectPartialRevert(BasisTrader.EdgeTooThin.selector);
        trader.exit(x);
    }

    function test_forceExitIgnoresFloorAndIsOwnerOnly() public {
        _openPosition();
        trader.setMarket(Mainnet.PERP_BTC, _btcMarket(0, 100_000));

        BasisTrader.ExitParams memory x = _exitParams(0, 0);

        vm.prank(keeper);
        vm.expectRevert();
        trader.forceExit(x);

        trader.forceExit(x);
        (PositionInfoV2 memory pos,,) = trader.position(Mainnet.PERP_BTC);
        assertEq(pos.lotLNS, 0, "forced unwind closed the short");
    }
}
