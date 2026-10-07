// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Order descriptor as the Perpl exchange takes it.
/// @dev Field names and order are copied verbatim from the deployed ABI
///      (`dex-sdk/crates/sdk/abi/dex/Exchange.json`); the tuple must encode
///      identically or `execOrders` reverts on decode.
///
///      Units, all fixed-point integers:
///      * `pricePNS`  price scaled by `10 ** priceDecimals` of the perpetual
///      * `lotLNS`    size  scaled by `10 ** lotDecimals` of the perpetual
///      * `amountCNS` collateral scaled by `10 ** 6` (AUSD)
///      * `leverageHdths` leverage in hundredths, so 2x is 200
struct OrderDesc {
    uint256 orderDescId;
    uint256 perpId;
    uint8 orderType;
    uint256 orderId;
    uint256 pricePNS;
    uint256 lotLNS;
    uint256 expiryBlock;
    bool postOnly;
    bool fillOrKill;
    bool immediateOrCancel;
    uint256 maxMatches;
    uint256 leverageHdths;
    uint256 lastExecutionBlock;
    uint256 amountCNS;
    uint256 maxNegPnlCollatBPS;
}

struct OrderSignature {
    uint256 perpId;
    uint256 orderId;
}

struct PerpetualInfoV2 {
    string name;
    string symbol;
    uint256 priceDecimals;
    uint256 lotDecimals;
    bytes32 linkFeedId;
    uint256 priceTolPer100K;
    uint256 marginTol;
    uint256 marginTolDecimals;
    uint256 refPriceMaxAgeSec;
    uint256 positionBalanceCNS;
    uint256 insuranceBalanceCNS;
    uint256 markPNS;
    uint256 markTimestamp;
    uint256 lastPNS;
    uint256 lastTimestamp;
    uint256 oraclePNS;
    uint256 oracleTimestampSec;
    uint256 longOpenInterestLNS;
    uint256 shortOpenInterestLNS;
    uint256 fundingStartBlock;
    int16 fundingRatePct100k;
    uint256 absFundingClampPctPer100K;
    uint8 status;
    uint256 basePricePNS;
    uint256 maxBidPriceONS;
    uint256 minBidPriceONS;
    uint256 maxAskPriceONS;
    uint256 minAskPriceONS;
    uint256 numOrders;
    bool ignOracle;
    uint256 fundingSumScalingExp;
}

struct PositionInfoV2 {
    uint256 accountId;
    uint256 nextNodeId;
    uint256 prevNodeId;
    uint8 positionType;
    uint256 depositCNS;
    uint256 pricePNS;
    uint256 lotLNS;
    uint256 entryBlock;
    int256 pnlCNS;
    int256 deltaPnlCNS;
    int256 premiumPnlCNS;
    uint256 priceResiduePNSQ16;
}

/// @dev Order IDs come from a bounded index and are reused once an order
///      leaves the book, so an ID identifies our order only together with
///      our `accountId`.
struct OrderV2 {
    uint32 accountId;
    uint8 orderType;
    uint24 priceONS;
    uint40 lotLNS;
    uint16 recycleFeeRaw;
    uint32 expiryBlock;
    uint16 leverageHdths;
    uint16 orderId;
    uint16 prevOrderId;
    uint16 nextOrderId;
    uint16 maxNegPnlCollatBPS;
    uint8 builderId;
    uint16 builderFeePer100K;
}

struct OrderLock {
    uint32 orderLockId;
    uint32 nextOrderLockId;
    uint32 prevOrderLockId;
    uint8 orderType;
    uint40 lotLNS;
    uint80 amountCNS;
}

struct PositionBitMap {
    uint256 bank1;
    uint256 bank2;
    uint256 bank3;
    uint256 bank4;
}

struct AccountInfo {
    uint256 accountId;
    uint256 balanceCNS;
    uint256 lockedBalanceCNS;
    uint8 frozen;
    address accountAddr;
    PositionBitMap positions;
}

/// @notice Subset of the Perpl exchange the basis trader calls.
/// @dev `OrderDescEnum`: 0 OpenLong, 1 OpenShort, 2 CloseLong, 3 CloseShort,
///      4 Cancel, 5 IncreasePositionCollateral, 6 Change.
interface IPerplExchange {
    function createAccount(uint256 amountCNS) external returns (uint256 accountId);
    function depositCollateral(uint256 amountCNS) external;
    function withdrawCollateral(uint256 amountCNS) external;
    function execOrder(OrderDesc calldata orderDesc) external returns (OrderSignature memory);
    function execOrders(OrderDesc[] calldata orderDescs, bool revertOnFail) external;
    function increasePositionCollateral(uint256 perpId, uint256 amountCNS) external;

    function getPerpetualInfoV2(uint256 perpId) external view returns (PerpetualInfoV2 memory);
    function getPositionV2(uint256 perpId, uint256 accountId)
        external
        view
        returns (PositionInfoV2 memory positionInfo, uint256 markPricePNS, bool markPriceValid);
    function getTakerFee(uint256 perpId) external view returns (uint256);
    function getExchangeInfo()
        external
        view
        returns (
            uint256 balanceCNS,
            uint256 protocolBalanceCNS,
            uint256 recycleBalanceCNS,
            uint256 collateralDecimals,
            address collateralToken,
            address verifierProxy
        );
    function getAccountByAddr(address accountAddress) external view returns (AccountInfo memory);
    function getAccountById(uint256 accountId) external view returns (AccountInfo memory);
    function getOrderV2(uint256 perpId, uint256 orderId) external view returns (OrderV2 memory);
    function getPerpOrderLocks(uint256 accountId, uint256 perpId) external view returns (OrderLock[] memory);
    function getMinAccountOpenCNS() external view returns (uint256);
}
