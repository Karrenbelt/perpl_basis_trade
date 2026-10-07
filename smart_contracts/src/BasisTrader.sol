// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {
    IPerplExchange,
    OrderDesc,
    OrderSignature,
    PerpetualInfoV2,
    PositionInfoV2,
    AccountInfo,
    OrderV2
} from "./interfaces/IPerplExchange.sol";
import {IKuruRouter} from "./interfaces/IKuru.sol";
import {BasisMath} from "./libraries/BasisMath.sol";

/// @title BasisTrader
/// @notice Atomic cash-and-carry between Kuru spot and Perpl perpetuals, both
///         settled in AUSD.
///
/// `enter` buys the spot asset on Kuru with AUSD and shorts the matching Perpl
/// perpetual in the same transaction; `exit` unwinds both the same way. Each
/// call measures what the two legs *actually* filled and reverts unless the
/// realised edge, net of every fee, clears the market's floor - so a trade that
/// stops being worth doing between quote and inclusion costs gas and nothing
/// else.
///
/// Both legs are taker-only and fill-or-kill. There is deliberately no path
/// that leaves one leg on and the other off: a short spot fill, a short perp
/// fill, or a thin edge all unwind the whole transaction.
contract BasisTrader is Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using BasisMath for PositionInfoV2;

    // --------------------------------------------------------------------
    // Types
    // --------------------------------------------------------------------

    /// @notice Perpl `OrderDescEnum`.
    uint8 internal constant ORDER_OPEN_SHORT = 1;
    uint8 internal constant ORDER_CLOSE_SHORT = 3;
    uint8 internal constant ORDER_CANCEL = 4;

    /// @notice Perpl `PositionEnum`: `Long = 0`, `Short = 1`.
    uint8 internal constant POSITION_SHORT = 1;

    uint256 internal constant BPS = 10_000;

    struct Market {
        bool enabled;
        /// Spot token bought against `cashToken`. `address(0)` means native MON.
        address spotToken;
        /// Stable the spot leg trades against. Kuru has no tradeable AUSD book
        /// for any of these assets, so in practice this is USDC while AUSD
        /// stays behind on Perpl as margin.
        address cashToken;
        uint8 spotDecimals;
        /// Cached from `getPerpetualInfoV2` at registration so the hot path
        /// does not pay for the full perpetual struct on every trade.
        uint8 priceDecimals;
        uint8 lotDecimals;
        /// Leverage in hundredths, as Perpl takes it: 200 is 2x.
        uint16 leverageHdths;
        /// Cap on collateral Perpl may draw to cover negative unrealised PnL
        /// on a fill, in bps of notional.
        uint16 maxNegPnlCollatBps;
        /// Largest share of the spot fill allowed to go unhedged because it
        /// does not round up to a whole lot, in ppm.
        uint32 maxHedgeDriftPpm;
        /// Floor on realised entry edge, ppm of spot notional, net of fees.
        int64 minEntryEdgePpm;
        /// Floor on realised exit edge, ppm of perp notional, net of fees.
        int64 minExitEdgePpm;
        /// Band the per-call `cashPegPpm` must fall inside, as AUSD per unit of
        /// `cashToken` in ppm. Exactly `1e6` on both sides when the cash token
        /// *is* AUSD. The band is owner-set and the peg is keeper-set, so a
        /// keeper can price a moving stable pair but cannot invent an edge by
        /// claiming USDC is worth two AUSD.
        uint32 minCashPegPpm;
        uint32 maxCashPegPpm;
    }

    struct EnterParams {
        uint256 perpId;
        /// `cashToken` to commit to the spot leg.
        uint256 cashIn;
        /// AUSD per unit of `cashToken`, ppm. Must fall inside the market band.
        uint32 cashPegPpm;
        /// Kuru orderbooks to walk, in order; one element is a direct book.
        address[] route;
        bool[] isBuy;
        bool[] nativeSend;
        /// Slippage floor on the spot leg, in `spotToken` units.
        uint256 minAssetOut;
        /// Worst short price accepted, in PNS.
        uint256 perplLimitPricePNS;
        /// Sanity band on the hedge the contract derives from the spot fill.
        uint256 minLotLNS;
        uint256 maxLotLNS;
        /// Collateral posted against the short, in CNS.
        uint256 marginCNS;
        uint256 maxMatches;
        uint256 requestId;
    }

    struct ExitParams {
        uint256 perpId;
        /// `spotToken` units to sell. Zero sells the whole balance.
        uint256 assetIn;
        /// AUSD per unit of `cashToken`, ppm. Must fall inside the market band.
        uint32 cashPegPpm;
        address[] route;
        bool[] isBuy;
        bool[] nativeSend;
        /// Slippage floor on the spot leg, in `cashToken`.
        uint256 minCashOut;
        /// Worst buy-back price accepted, in PNS.
        uint256 perplLimitPricePNS;
        uint256 maxMatches;
        uint256 requestId;
    }

    struct HedgeParams {
        uint256 perpId;
        /// Short to rest on the book, in lots.
        uint256 lotLNS;
        /// Price the short rests at, in PNS. Post-only: a price that would
        /// cross the book reverts in Perpl.
        uint256 pricePNS;
        /// AUSD moved from this contract into the Perpl account first, in CNS.
        /// Zero leaves the order to draw on the account's existing balance.
        uint256 marginCNS;
        uint256 requestId;
    }

    struct Fill {
        uint256 perpId;
        /// Spot leg in AUSD terms, converted at `cashPegPpm`, and covering only
        /// the part the perp leg hedges: on entry the share of the cash that
        /// bought `lotLNS` worth of asset, on exit the proceeds of selling
        /// exactly that much back.
        uint256 spotNotionalCNS;
        /// Asset bought (entry) or sold (exit), in `spotToken` units.
        uint256 assetAmount;
        /// Perp notional opened (entry) or closed (exit), in CNS.
        uint256 perpNotionalCNS;
        uint256 lotLNS;
        /// Realised edge net of every fee, ppm.
        int256 edgePpm;
    }

    // --------------------------------------------------------------------
    // Storage
    // --------------------------------------------------------------------

    IERC20 public immutable AUSD;
    IPerplExchange public immutable PERPL;
    IKuruRouter public immutable KURU_ROUTER;

    /// @notice Perpl account this contract trades through. Zero until opened.
    uint256 public perplAccountId;

    mapping(uint256 perpId => Market) public markets;
    mapping(address keeper => bool) public keepers;

    /// @notice Perpl order ID of the post-only hedge resting on each market;
    ///         zero when none rests. At most one per market.
    mapping(uint256 perpId => uint256 orderId) public restingHedge;

    /// @notice Largest discount to Perpl's oracle, in bps, at which `hedge`
    ///         may rest a short.
    mapping(uint256 perpId => uint16) public hedgeMaxDiscountBps;
    /// @notice Oldest Perpl oracle, in seconds, that `hedge` prices against.
    ///         Zero means no bound is set, and `hedge` refuses.
    mapping(uint256 perpId => uint32) public hedgeMaxOracleAgeSec;

    // --------------------------------------------------------------------
    // Events
    // --------------------------------------------------------------------

    event PerplAccountOpened(uint256 indexed accountId, uint256 amountCNS);
    event MarketSet(uint256 indexed perpId, Market market);
    event KeeperSet(address indexed keeper, bool allowed);
    event Entered(uint256 indexed perpId, uint256 indexed requestId, Fill fill);
    event Exited(uint256 indexed perpId, uint256 indexed requestId, Fill fill, bool forced);
    event HedgePosted(
        uint256 indexed perpId, uint256 indexed requestId, uint256 orderId, uint256 lotLNS, uint256 pricePNS
    );
    /// @dev `unfilledLotLNS` is zero whenever no order of ours remained at the
    ///      ID: a full fill, but also an order Perpl removed itself (an admin
    ///      or liquidator cancel). It does not prove a fill; filled lots are
    ///      read from the position.
    event HedgeCancelled(
        uint256 indexed perpId, uint256 indexed requestId, uint256 orderId, uint256 unfilledLotLNS
    );
    event HedgeBoundSet(uint256 indexed perpId, uint16 maxDiscountBps, uint32 maxOracleAgeSec);
    event MarginDeposited(uint256 amountCNS);
    event MarginWithdrawn(uint256 amountCNS);
    event PositionToppedUp(uint256 indexed perpId, uint256 amountCNS);
    event Funded(address indexed token, uint256 amount);
    event Swept(address indexed token, address indexed to, uint256 amount);

    // --------------------------------------------------------------------
    // Errors
    // --------------------------------------------------------------------

    error NotKeeper();
    error MarketDisabled(uint256 perpId);
    error AccountNotOpen();
    error AccountAlreadyOpen();
    error EmptyRoute();
    error RouteLengthMismatch();
    error SpotFillTooSmall(uint256 got, uint256 want);
    error LotsOutOfBand(uint256 lots, uint256 min, uint256 max);
    error HedgeDrift(uint256 driftPpm, uint256 maxPpm);
    error PerpLegNotFilled();
    error PerpLegOverfilled(uint256 filled, uint256 requested);
    error NotShort(uint8 positionType);
    error EdgeTooThin(int256 edgePpm, int256 minPpm);
    error NegativeEdgeFloor();
    error NothingToExit();
    error NativeTransferFailed();
    error SizeOverflow(uint256 value);
    error PegOutOfBand(uint32 peg, uint32 min, uint32 max);
    error BadPegBand();
    error ZeroAddress();
    error HedgeResting(uint256 perpId, uint256 orderId);
    error NoRestingHedge(uint256 perpId);
    error Unhedgeable(uint256 shortAmount, uint256 heldAmount);
    error HedgeNotPosted(uint256 orderId);
    error HedgeNotCancelled(uint256 orderId);
    error BadHedgeBound();
    error HedgeBoundNotSet(uint256 perpId);
    error OracleUnusable(uint256 perpId);
    error OracleStale(uint256 oracleTimestampSec, uint256 maxAgeSec);
    error HedgeBelowOracle(uint256 pricePNS, uint256 oraclePNS, uint256 maxDiscountBps);

    // --------------------------------------------------------------------
    // Setup
    // --------------------------------------------------------------------

    constructor(address ausd, address perpl, address kuruRouter, address initialOwner) Ownable(initialOwner) {
        AUSD = IERC20(ausd);
        PERPL = IPerplExchange(perpl);
        KURU_ROUTER = IKuruRouter(kuruRouter);
    }

    receive() external payable {}

    modifier onlyKeeper() {
        _requireKeeper();
        _;
    }

    /// @dev Body of `onlyKeeper`, out of line so the check is not inlined into
    ///      every guarded function.
    function _requireKeeper() internal view {
        if (!keepers[msg.sender] && msg.sender != owner()) revert NotKeeper();
    }

    /// @notice Open this contract's Perpl account, seeding it with `amountCNS` AUSD.
    /// @dev Perpl keys accounts by address, so the contract - not the operator -
    ///      must be the one to call `createAccount`, and it can only ever have one.
    function openPerplAccount(uint256 amountCNS) external nonReentrant onlyOwner returns (uint256 accountId) {
        if (perplAccountId != 0) revert AccountAlreadyOpen();
        AUSD.forceApprove(address(PERPL), amountCNS);
        accountId = PERPL.createAccount(amountCNS);
        AUSD.forceApprove(address(PERPL), 0);
        perplAccountId = accountId;
        emit PerplAccountOpened(accountId, amountCNS);
    }

    /// @notice Register or update a tradeable pair.
    /// @dev `priceDecimals`/`lotDecimals` are read from Perpl rather than taken
    ///      from the caller: getting either wrong silently misprices every edge
    ///      check on the market by a power of ten.
    function setMarket(uint256 perpId, Market memory market) external onlyOwner {
        if (market.minEntryEdgePpm < 0) revert NegativeEdgeFloor();
        if (market.minCashPegPpm == 0 || market.minCashPegPpm > market.maxCashPegPpm) revert BadPegBand();
        PerpetualInfoV2 memory info = PERPL.getPerpetualInfoV2(perpId);
        market.priceDecimals = SafeCast.toUint8(info.priceDecimals);
        market.lotDecimals = SafeCast.toUint8(info.lotDecimals);
        markets[perpId] = market;
        emit MarketSet(perpId, market);
    }

    function setKeeper(address keeper, bool allowed) external onlyOwner {
        keepers[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    /// @notice Bound the price `hedge` may rest a short at, against Perpl's oracle.
    /// @dev Without it the keeper alone chooses the price, and could rest the
    ///      short under a bid it has depressed and fill it from its own account.
    function setHedgeBound(uint256 perpId, uint16 maxDiscountBps, uint32 maxOracleAgeSec) external onlyOwner {
        if (maxDiscountBps >= BPS || maxOracleAgeSec == 0) revert BadHedgeBound();
        hedgeMaxDiscountBps[perpId] = maxDiscountBps;
        hedgeMaxOracleAgeSec[perpId] = maxOracleAgeSec;
        emit HedgeBoundSet(perpId, maxDiscountBps, maxOracleAgeSec);
    }

    // --------------------------------------------------------------------
    // Treasury
    // --------------------------------------------------------------------

    /// @notice Pull working capital in from the owner.
    /// @dev Takes the token because the two legs are funded in different
    ///      stables: AUSD backs the Perpl margin, while the spot leg is bought
    ///      with whatever `cashToken` the market trades against.
    function fund(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(token, amount);
    }

    function sweep(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        emit Swept(token, to, amount);
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// @notice Move AUSD from this contract into the Perpl account's free balance.
    function depositMargin(uint256 amountCNS) public onlyKeeper {
        if (perplAccountId == 0) revert AccountNotOpen();
        emit MarginDeposited(amountCNS);
        AUSD.forceApprove(address(PERPL), amountCNS);
        // Reached from `hedge` before it records the order ID, which exists
        // only after the order call; `hedge` is `nonReentrant`.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        PERPL.depositCollateral(amountCNS);
        AUSD.forceApprove(address(PERPL), 0);
    }

    /// @notice Pull AUSD out of the Perpl account back into this contract.
    /// @dev Perpl rate-limits withdrawals, so this is a separate owner call
    ///      rather than something `exit` does inline - a throttled withdrawal
    ///      must not be able to revert an otherwise good unwind.
    function withdrawMargin(uint256 amountCNS) external onlyOwner {
        emit MarginWithdrawn(amountCNS);
        PERPL.withdrawCollateral(amountCNS);
    }

    /// @notice Add collateral to an open position that has drifted toward its
    ///         maintenance margin.
    function topUpPosition(uint256 perpId, uint256 amountCNS) external onlyKeeper {
        emit PositionToppedUp(perpId, amountCNS);
        PERPL.increasePositionCollateral(perpId, amountCNS);
    }

    // --------------------------------------------------------------------
    // Enter
    // --------------------------------------------------------------------

    /// @notice Buy spot on Kuru and short the matching perpetual, atomically.
    /// @dev Order matters: the spot leg goes first so the hedge can be sized
    ///      from what actually filled rather than from a quote that may be
    ///      stale by inclusion. The perp leg is then fill-or-kill against that
    ///      exact size, and the edge is checked against both realised fills.
    function enter(EnterParams calldata p) external nonReentrant onlyKeeper returns (Fill memory fill) {
        Market memory m = markets[p.perpId];
        if (!m.enabled) revert MarketDisabled(p.perpId);
        if (perplAccountId == 0) revert AccountNotOpen();

        _checkPeg(m, p.cashPegPpm);

        if (p.marginCNS != 0) depositMargin(p.marginCNS);

        uint256 assetOut = _buySpot(m, p);
        if (assetOut < p.minAssetOut) revert SpotFillTooSmall(assetOut, p.minAssetOut);

        uint256 lotLNS = BasisMath.tokenToLots(assetOut, m.spotDecimals, m.lotDecimals);
        if (lotLNS < p.minLotLNS || lotLNS > p.maxLotLNS) {
            revert LotsOutOfBand(lotLNS, p.minLotLNS, p.maxLotLNS);
        }

        uint256 hedged = BasisMath.lotsToToken(lotLNS, m.spotDecimals, m.lotDecimals);
        uint256 driftPpm = ((assetOut - hedged) * BasisMath.PPM) / assetOut;
        if (driftPpm > m.maxHedgeDriftPpm) revert HedgeDrift(driftPpm, m.maxHedgeDriftPpm);

        (uint256 perpNotionalCNS, uint256 filledLots) = _tradePerp(
            m,
            p.perpId,
            ORDER_OPEN_SHORT,
            p.perplLimitPricePNS,
            lotLNS,
            p.marginCNS,
            p.maxMatches,
            p.requestId
        );
        if (filledLots != lotLNS) revert PerpLegOverfilled(filledLots, lotLNS);

        // Compare like for like. The short covers `hedged`, not the whole spot
        // fill, so the edge is measured against what `hedged` cost - not
        // against every unit of cash spent. Charging the rounding dust to the
        // edge would price a whole lot of granularity as a total loss, which on
        // a market with coarse lots swamps the basis it is meant to measure.
        // The dust is a real directional exposure, but a small one, and it is
        // what `maxHedgeDriftPpm` is there to bound.
        //
        // Kuru's taker fee and its slippage are already inside `cashIn /
        // assetOut`; only Perpl's taker fee still has to come off by hand.
        uint256 spotNotionalCNS = Math.mulDiv(p.cashIn * p.cashPegPpm, hedged, BasisMath.PPM * assetOut);
        int256 edgePpm = BasisMath.relativePpm(perpNotionalCNS, spotNotionalCNS)
            - SafeCast.toInt256(PERPL.getTakerFee(p.perpId));
        if (edgePpm < m.minEntryEdgePpm) revert EdgeTooThin(edgePpm, m.minEntryEdgePpm);

        fill = Fill({
            perpId: p.perpId,
            spotNotionalCNS: spotNotionalCNS,
            assetAmount: assetOut,
            perpNotionalCNS: perpNotionalCNS,
            lotLNS: lotLNS,
            edgePpm: edgePpm
        });
        emit Entered(p.perpId, p.requestId, fill);
    }

    // --------------------------------------------------------------------
    // Hedge
    // --------------------------------------------------------------------

    /// @notice Rest a post-only short against spot this contract already
    ///         holds, so the hedge is paid the maker side of the spread.
    /// @dev The short, filled and resting, never exceeds the spot held: a
    ///      late fill is still hedged. Perpl defines some failures as events
    ///      (`OrderPostFailed`), so the order is read back before it is recorded.
    function hedge(HedgeParams calldata p) external nonReentrant onlyKeeper returns (uint256 orderId) {
        Market memory m = markets[p.perpId];
        if (!m.enabled) revert MarketDisabled(p.perpId);
        uint256 accountId = perplAccountId;
        if (accountId == 0) revert AccountNotOpen();
        uint256 resting = restingHedge[p.perpId];
        if (resting != 0) revert HedgeResting(p.perpId, resting);
        _checkHedgePrice(p.perpId, p.pricePNS);

        // Perpl has no position getter without the mark; it is not needed here.
        // forge-lint: disable-next-line(unused-return)
        (PositionInfoV2 memory pos,,) = PERPL.getPositionV2(p.perpId, accountId);
        if (pos.lotLNS != 0 && pos.positionType != POSITION_SHORT) revert NotShort(pos.positionType);
        uint256 shortAmount = BasisMath.lotsToToken(pos.lotLNS + p.lotLNS, m.spotDecimals, m.lotDecimals);
        uint256 held = _spotBalance(m.spotToken);
        if (shortAmount > held) revert Unhedgeable(shortAmount, held);

        if (p.marginCNS != 0) depositMargin(p.marginCNS);

        // The order ID exists only once Perpl has accepted the order, so the
        // record is written after the call; `nonReentrant` covers the gap.
        // forge-lint: disable-start(reentrancy-no-eth)
        OrderSignature memory sig = PERPL.execOrder(
            OrderDesc({
                orderDescId: p.requestId,
                perpId: p.perpId,
                orderType: ORDER_OPEN_SHORT,
                orderId: 0,
                pricePNS: p.pricePNS,
                lotLNS: p.lotLNS,
                expiryBlock: 0,
                postOnly: true,
                fillOrKill: false,
                immediateOrCancel: false,
                maxMatches: 0,
                leverageHdths: m.leverageHdths,
                lastExecutionBlock: 0,
                amountCNS: 0,
                maxNegPnlCollatBPS: m.maxNegPnlCollatBps
            })
        );
        // forge-lint: disable-end(reentrancy-no-eth)
        orderId = sig.orderId;

        OrderV2 memory o = PERPL.getOrderV2(p.perpId, orderId);
        if (o.accountId != accountId || o.lotLNS != p.lotLNS) revert HedgeNotPosted(orderId);

        restingHedge[p.perpId] = orderId;
        // forge-lint: disable-next-line(reentrancy-events)
        emit HedgePosted(p.perpId, p.requestId, orderId, p.lotLNS, p.pricePNS);
    }

    /// @notice Take the resting hedge off the book, or forget it if it has
    ///         filled, which unblocks `exit`.
    /// @dev Reverts unless the order is gone afterwards: clearing the record
    ///      while the ask still rests would let `exit` sell the spot under a
    ///      short that can still grow.
    function cancelHedge(uint256 perpId, uint256 requestId)
        external
        nonReentrant
        onlyKeeper
        returns (uint256 unfilledLotLNS)
    {
        uint256 orderId = restingHedge[perpId];
        if (orderId == 0) revert NoRestingHedge(perpId);
        delete restingHedge[perpId];

        uint256 accountId = perplAccountId;
        OrderV2 memory o = PERPL.getOrderV2(perpId, orderId);
        bool live = o.accountId == accountId;
        if (live) unfilledLotLNS = o.lotLNS;
        emit HedgeCancelled(perpId, requestId, orderId, unfilledLotLNS);
        if (!live) return unfilledLotLNS;

        // The returned signature carries nothing a cancel needs; the read-back
        // below is what decides.
        // forge-lint: disable-start(unused-return)
        PERPL.execOrder(
            OrderDesc({
                orderDescId: requestId,
                perpId: perpId,
                orderType: ORDER_CANCEL,
                orderId: orderId,
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
            })
        );
        // forge-lint: disable-end(unused-return)
        if (PERPL.getOrderV2(perpId, orderId).accountId == accountId) revert HedgeNotCancelled(orderId);
    }

    // --------------------------------------------------------------------
    // Exit
    // --------------------------------------------------------------------

    /// @notice Close the short and sell the spot back to AUSD, atomically.
    function exit(ExitParams calldata p) external nonReentrant onlyKeeper returns (Fill memory fill) {
        return _exit(p, false);
    }

    /// @notice Unwind ignoring the edge floor.
    /// @dev The edge gate exists to stop the contract opening a bad trade, but
    ///      a position already on can need to come off at a price the gate
    ///      would refuse - margin pressure, funding turning against the short.
    ///      Owner-only, because skipping the gate is exactly the power the
    ///      keeper is not meant to have.
    function forceExit(ExitParams calldata p) external nonReentrant onlyOwner returns (Fill memory fill) {
        return _exit(p, true);
    }

    function _exit(ExitParams calldata p, bool forced) internal returns (Fill memory fill) {
        Market memory m = markets[p.perpId];
        if (!m.enabled) revert MarketDisabled(p.perpId);
        if (perplAccountId == 0) revert AccountNotOpen();
        // A resting ask could fill after the spot is sold, and could match
        // the buy-back below against ourselves.
        uint256 resting = restingHedge[p.perpId];
        if (resting != 0) revert HedgeResting(p.perpId, resting);

        _checkPeg(m, p.cashPegPpm);

        uint256 assetIn = p.assetIn == 0 ? _spotBalance(m.spotToken) : p.assetIn;
        if (assetIn == 0) revert NothingToExit();

        uint256 lotLNS = BasisMath.tokenToLots(assetIn, m.spotDecimals, m.lotDecimals);
        if (lotLNS == 0) revert NothingToExit();

        // Perp first on the way out: the short is the leg that can be forced
        // shut by the exchange, so it is the one worth closing while the
        // transaction still has the option to revert.
        (uint256 perpNotionalCNS, uint256 filledLots) = _tradePerp(
            m, p.perpId, ORDER_CLOSE_SHORT, p.perplLimitPricePNS, lotLNS, 0, p.maxMatches, p.requestId
        );
        if (filledLots != lotLNS) revert PerpLegOverfilled(filledLots, lotLNS);

        uint256 sellAmount = BasisMath.lotsToToken(lotLNS, m.spotDecimals, m.lotDecimals);
        uint256 cashOut = _sellSpot(m, p, sellAmount);
        if (cashOut < p.minCashOut) revert SpotFillTooSmall(cashOut, p.minCashOut);

        // Mirror of the entry gate: on the way out the spot sale is the credit
        // and buying the short back is the debit.
        uint256 spotNotionalCNS = (cashOut * p.cashPegPpm) / BasisMath.PPM;
        int256 edgePpm = BasisMath.relativePpm(spotNotionalCNS, perpNotionalCNS)
            - SafeCast.toInt256(PERPL.getTakerFee(p.perpId));
        if (!forced && edgePpm < m.minExitEdgePpm) revert EdgeTooThin(edgePpm, m.minExitEdgePpm);

        fill = Fill({
            perpId: p.perpId,
            spotNotionalCNS: spotNotionalCNS,
            assetAmount: sellAmount,
            perpNotionalCNS: perpNotionalCNS,
            lotLNS: lotLNS,
            edgePpm: edgePpm
        });
        emit Exited(p.perpId, p.requestId, fill, forced);
    }

    // --------------------------------------------------------------------
    // Legs
    // --------------------------------------------------------------------

    /// @dev Returns the asset gained measured from this contract's own balance
    ///      rather than from the venue's return value, so a router that credits
    ///      less than it reports cannot inflate the hedge.
    function _buySpot(Market memory m, EnterParams calldata p) internal returns (uint256) {
        uint256 before = _spotBalance(m.spotToken);

        _validateRoute(p.route, p.isBuy, p.nativeSend);
        IERC20(m.cashToken).forceApprove(address(KURU_ROUTER), p.cashIn);
        KURU_ROUTER.anyToAnySwap(
            p.route, p.isBuy, p.nativeSend, m.cashToken, m.spotToken, p.cashIn, p.minAssetOut
        );
        IERC20(m.cashToken).forceApprove(address(KURU_ROUTER), 0);

        return _spotBalance(m.spotToken) - before;
    }

    function _sellSpot(Market memory m, ExitParams calldata p, uint256 amount) internal returns (uint256) {
        uint256 before = IERC20(m.cashToken).balanceOf(address(this));
        bool native = m.spotToken == address(0);

        _validateRoute(p.route, p.isBuy, p.nativeSend);
        if (!native) IERC20(m.spotToken).forceApprove(address(KURU_ROUTER), amount);
        KURU_ROUTER.anyToAnySwap{value: native ? amount : 0}(
            p.route, p.isBuy, p.nativeSend, m.spotToken, m.cashToken, amount, p.minCashOut
        );
        if (!native) IERC20(m.spotToken).forceApprove(address(KURU_ROUTER), 0);

        return IERC20(m.cashToken).balanceOf(address(this)) - before;
    }

    /// @dev Posts one taker order and prices it from the change in the position
    ///      itself. Perpl reports a fill through state, not a return value, and
    ///      an order added to a position already on the books only moves the
    ///      weighted average - so the notional that matters is the difference
    ///      between the two snapshots, taken before anything is rounded.
    function _tradePerp(
        Market memory m,
        uint256 perpId,
        uint8 orderType,
        uint256 limitPricePNS,
        uint256 lotLNS,
        uint256 marginCNS,
        uint256 maxMatches,
        uint256 requestId
    ) internal returns (uint256 notionalCNS, uint256 filledLots) {
        uint256 accountId = perplAccountId;
        (PositionInfoV2 memory before,,) = PERPL.getPositionV2(perpId, accountId);

        PERPL.execOrder(
            OrderDesc({
                orderDescId: requestId,
                perpId: perpId,
                orderType: orderType,
                orderId: 0,
                pricePNS: limitPricePNS,
                lotLNS: lotLNS,
                expiryBlock: 0,
                postOnly: false,
                fillOrKill: true,
                immediateOrCancel: true,
                maxMatches: maxMatches,
                leverageHdths: m.leverageHdths,
                lastExecutionBlock: 0,
                amountCNS: marginCNS,
                maxNegPnlCollatBPS: m.maxNegPnlCollatBps
            })
        );

        (PositionInfoV2 memory post,,) = PERPL.getPositionV2(perpId, accountId);
        if (post.lotLNS != 0 && post.positionType != POSITION_SHORT) revert NotShort(post.positionType);

        filledLots = BasisMath.absDiff(post.lotLNS, before.lotLNS);
        if (filledLots == 0) revert PerpLegNotFilled();

        uint256 notionalQ16 = BasisMath.absDiff(post.notionalQ16(), before.notionalQ16());
        notionalCNS = BasisMath.notionalQ16ToCNS(notionalQ16, m.priceDecimals, m.lotDecimals);
    }

    // --------------------------------------------------------------------
    // Views and helpers
    // --------------------------------------------------------------------

    function position(uint256 perpId)
        external
        view
        returns (PositionInfoV2 memory info, uint256 markPricePNS, bool markValid)
    {
        return PERPL.getPositionV2(perpId, perplAccountId);
    }

    function perplAccount() external view returns (AccountInfo memory) {
        return PERPL.getAccountByAddr(address(this));
    }

    /// @dev A keeper prices the stable pair, the owner bounds how far it may
    ///      claim it has moved. Without the band a keeper could pass an
    ///      arbitrary peg and make any trade clear the edge gate.
    function _checkPeg(Market memory m, uint32 peg) internal pure {
        if (peg < m.minCashPegPpm || peg > m.maxCashPegPpm) {
            revert PegOutOfBand(peg, m.minCashPegPpm, m.maxCashPegPpm);
        }
    }

    /// @dev Fails closed: no bound, an oracle Perpl does not use, and a stale
    ///      oracle all refuse. The age is stored rather than read from Perpl's
    ///      `refPriceMaxAgeSec` so that it holds if Perpl raises its own limit.
    ///      `price × BPS ≥ oracle × (BPS − discount)` has no division, so no
    ///      rounding; both prices are in the perpetual's PNS.
    function _checkHedgePrice(uint256 perpId, uint256 pricePNS) internal view {
        uint256 maxAgeSec = hedgeMaxOracleAgeSec[perpId];
        if (maxAgeSec == 0) revert HedgeBoundNotSet(perpId);
        PerpetualInfoV2 memory info = PERPL.getPerpetualInfoV2(perpId);
        if (info.oraclePNS == 0 || info.ignOracle) revert OracleUnusable(perpId);
        // The oracle's age is only defined against block time; a skew of a few
        // seconds is small against an age limit of tens of seconds.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > info.oracleTimestampSec + maxAgeSec) {
            revert OracleStale(info.oracleTimestampSec, maxAgeSec);
        }
        uint256 maxDiscountBps = hedgeMaxDiscountBps[perpId];
        if (pricePNS * BPS < info.oraclePNS * (BPS - maxDiscountBps)) {
            revert HedgeBelowOracle(pricePNS, info.oraclePNS, maxDiscountBps);
        }
    }

    function _spotBalance(address token) internal view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    function _validateRoute(address[] calldata route, bool[] calldata isBuy, bool[] calldata nativeSend)
        internal
        pure
    {
        if (route.length == 0) revert EmptyRoute();
        if (route.length != isBuy.length || route.length != nativeSend.length) {
            revert RouteLengthMismatch();
        }
    }

    /// @dev Kuru sizes orders in `uint96`. A silent truncation here would
    ///      submit an order for a fraction of the intended size and still look
    ///      like a clean fill, so it reverts instead.
    function _toUint96(uint256 value) internal pure returns (uint96) {
        if (value > type(uint96).max) revert SizeOverflow(value);
        // Bounded on the line above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint96(value);
    }
}
