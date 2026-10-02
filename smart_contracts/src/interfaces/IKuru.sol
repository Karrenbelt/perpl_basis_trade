// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Kuru's market factory, which also fronts routed multi-hop swaps.
/// @dev `anyToAnySwap` walks `_marketAddresses` in order, taking the `_isBuy[i]`
///      side of hop `i`, pulling `_amount` of `_debitToken` from `msg.sender`
///      via `transferFrom` and sending the proceeds back to `msg.sender`. The
///      caller picks the route; the contract only enforces `_minAmountOut`.
interface IKuruRouter {
    function anyToAnySwap(
        address[] calldata _marketAddresses,
        bool[] calldata _isBuy,
        bool[] calldata _nativeSend,
        address _debitToken,
        address _creditToken,
        uint256 _amount,
        uint256 _minAmountOut
    ) external payable returns (uint256);

    function marginAccountAddress() external view returns (address);
}

/// @notice One Kuru CLOB market.
/// @dev `placeAndExecuteMarketBuy` spends `_quoteSize` of the quote asset and
///      `placeAndExecuteMarketSell` sells `_size` of the base asset, both in the
///      market's own size precision rather than token decimals. `_isMargin`
///      draws from the Kuru margin account instead of the wallet; `_isFillOrKill`
///      reverts rather than partially filling.
interface IKuruOrderBook {
    function placeAndExecuteMarketBuy(
        uint96 _quoteSize,
        uint256 _minAmountOut,
        bool _isMargin,
        bool _isFillOrKill
    ) external payable returns (uint256);

    function placeAndExecuteMarketSell(
        uint96 _size,
        uint256 _minAmountOut,
        bool _isMargin,
        bool _isFillOrKill
    ) external payable returns (uint256);

    function bestBidAsk() external view returns (uint256 bestBid, uint256 bestAsk);

    function getMarketParams()
        external
        view
        returns (
            uint32 pricePrecision,
            uint96 sizePrecision,
            address baseAssetAddress,
            uint256 baseAssetDecimals,
            address quoteAssetAddress,
            uint256 quoteAssetDecimals,
            uint32 tickSize,
            uint96 minSize,
            uint96 maxSize,
            uint256 takerFeeBps,
            uint256 makerFeeBps
        );
}

interface IKuruMarginAccount {
    function deposit(address _user, address _token, uint256 _amount) external payable;
    function withdraw(uint256 _amount, address _token) external;
    function getBalance(address _user, address _token) external view returns (uint256);
}
