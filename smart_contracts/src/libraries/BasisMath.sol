// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PositionInfoV2} from "../interfaces/IPerplExchange.sol";

/// @title Fixed-point conversions between Perpl's three scales and token units.
/// @notice Perpl keeps prices in `PNS` (`10 ** priceDecimals`), sizes in `LNS`
///         (`10 ** lotDecimals`) and collateral in `CNS` (`10 ** 6`, AUSD).
///         Everything the edge check compares has to land in CNS first.
library BasisMath {
    /// @dev Perpl carries the sub-PNS remainder of a position's average entry
    ///      price as a Q16 fraction alongside the integer price. For a SHORT -
    ///      the only side this contract ever holds - the exact average is
    ///      `pricePNS + priceResiduePNSQ16 / 2**16`; the long side subtracts a
    ///      whole PNS unit first, which is why these helpers are not safe to
    ///      reuse for longs. Notionals are accumulated pre-division at the Q16
    ///      scale so differencing two snapshots keeps the remainder.
    uint256 internal constant Q16 = 1 << 16;

    uint256 internal constant PPM = 1e6;

    error PriceOverflow();
    error ScaleOverflow();

    /// @notice Short position notional at Q16 scale: `(pricePNS * 2**16 + residue) * lotLNS`.
    /// @dev Left undivided so a caller can difference two snapshots without
    ///      rounding each one first - the delta of two truncated notionals can
    ///      be off by a full PNS tick, which at BTC's single price decimal is
    ///      real money.
    function notionalQ16(PositionInfoV2 memory position) internal pure returns (uint256) {
        return (position.pricePNS * Q16 + position.priceResiduePNSQ16) * position.lotLNS;
    }

    /// @notice Convert a Q16-scaled notional into AUSD collateral units (CNS).
    /// @param notional Value from `notionalQ16`.
    /// @param priceDecimals `priceDecimals` of the perpetual.
    /// @param lotDecimals `lotDecimals` of the perpetual.
    function notionalQ16ToCNS(uint256 notional, uint256 priceDecimals, uint256 lotDecimals)
        internal
        pure
        returns (uint256)
    {
        if (priceDecimals + lotDecimals > 60) revert ScaleOverflow();
        return (notional * 1e6) / (Q16 * (10 ** (priceDecimals + lotDecimals)));
    }

    /// @notice Largest whole number of lots covering at most `amount` token units.
    /// @dev Rounds down: the hedge must never exceed the spot it covers, so the
    ///      remainder is left as unhedged dust the caller then bounds.
    function tokenToLots(uint256 amount, uint256 tokenDecimals, uint256 lotDecimals)
        internal
        pure
        returns (uint256)
    {
        if (tokenDecimals >= lotDecimals) {
            return amount / (10 ** (tokenDecimals - lotDecimals));
        }
        return amount * (10 ** (lotDecimals - tokenDecimals));
    }

    /// @notice Token units a lot count represents. Inverse of `tokenToLots`.
    function lotsToToken(uint256 lots, uint256 tokenDecimals, uint256 lotDecimals)
        internal
        pure
        returns (uint256)
    {
        if (tokenDecimals >= lotDecimals) {
            return lots * (10 ** (tokenDecimals - lotDecimals));
        }
        return lots / (10 ** (lotDecimals - tokenDecimals));
    }

    /// @notice `(value - basis) / basis` in parts per million, signed.
    /// @dev Parts per million because that is already Perpl's fee unit - a fee
    ///      schedule of 345 is 345 ppm is 3.45 bps - so fee and edge subtract
    ///      without a scale change.
    ///
    ///      The subtraction happens in unsigned arithmetic and the sign is
    ///      applied afterwards. Casting each operand to `int256` first would
    ///      read any notional above `2**255` as negative, and an edge check
    ///      that silently flips sign is the one failure mode this whole
    ///      contract exists to prevent.
    function relativePpm(uint256 value, uint256 basis) internal pure returns (int256) {
        if (basis == 0) revert PriceOverflow();

        bool gain = value >= basis;
        uint256 magnitude = (absDiff(value, basis) * PPM) / basis;
        // A ratio this extreme cannot come from two notionals of the same
        // asset; it means a caller passed something that is not a notional.
        if (magnitude > uint256(type(int256).max)) revert PriceOverflow();

        // Bounded above, so the cast cannot truncate or change sign.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 signed = int256(magnitude);
        return gain ? signed : -signed;
    }

    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
