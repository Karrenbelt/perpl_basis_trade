//! Typed contract bindings.
//!
//! `BasisTrader` is generated from the Foundry artifact rather than a hand
//! written `sol!` block, so the executor and the deployed bytecode can never
//! drift on a struct field. Build the contracts before the executor.
//!
//! `sol!` generates constructors as wide as the ABI structs they mirror, which
//! is wider than clippy's default. The shape is the chain's, not ours.
#![allow(clippy::too_many_arguments)]

use alloy::sol;

sol!(
    #[sol(rpc, all_derives)]
    BasisTrader,
    "../smart_contracts/out/BasisTrader.sol/BasisTrader.json"
);

// Every error the Perpl exchange can revert with. Carried so a failed
// simulation says `MarkPriceAgeExceedsMax` rather than a bare selector - most
// of what blocks a basis trade is thrown by Perpl, not by our own contract, and
// an operator reading the log needs the difference between "the oracle is
// stale" and "the book moved".
sol!(
    #[sol(rpc, all_derives)]
    PerplErrors,
    "abi/PerplErrors.json"
);

sol!(
    #[sol(rpc, all_derives)]
    interface IErc20 {
        function balanceOf(address owner) external view returns (uint256);
        function decimals() external view returns (uint8);
        function symbol() external view returns (string memory);
    }
);

sol!(
    #[sol(rpc, all_derives)]
    interface IPerplRead {
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

        function getPerpetualInfoV2(uint256 perpId) external view returns (PerpetualInfoV2 memory);
        function getTakerFee(uint256 perpId) external view returns (uint256);
    }
);
