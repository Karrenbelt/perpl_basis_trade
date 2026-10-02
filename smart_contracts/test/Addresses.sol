// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Live Monad mainnet (chain 143) deployments the fork tests pin to.
/// @dev Kuru lists several orderbooks per pair; the ones here are the books
///      carrying the volume, chosen from the indexer's 24h figures rather than
///      from the docs, which list older deployments.
library Mainnet {
    address internal constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address internal constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    address internal constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address internal constant CBBTC = 0xd18B7EC58Cdf4876f6AFebd3Ed1730e4Ce10414b;
    address internal constant WETH = 0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242;

    address internal constant PERPL_EXCHANGE = 0x34B6552d57a35a1D042CcAe1951BD1C370112a6F;
    address internal constant KURU_ROUTER = 0xd651346d7c789536ebf06dc72aE3C8502cd695CC;
    address internal constant KURU_MARGIN_ACCOUNT = 0x2A68ba1833cDf93fa9Da1EEbd7F46242aD8E90c5;

    // Kuru orderbooks.
    address internal constant BOOK_AUSD_USDC = 0x699AbC15308156E9a3AB89Ec7387e9CfE1c86A3b;
    address internal constant BOOK_CBBTC_USDC = 0x40c49F171202F91ff5d2faE34c22dD2BFdD22aF0;
    address internal constant BOOK_WETH_USDC = 0xa6aFD386135B7D41A6C40C525abC4A1019b0D132;
    address internal constant BOOK_MON_USDC = 0x065C9d28E428A0db40191a54d33d5b7c71a9C394;

    // Perpl perpetual ids.
    uint256 internal constant PERP_BTC = 1;
    uint256 internal constant PERP_MON = 10;
    uint256 internal constant PERP_ETH = 20;
}
