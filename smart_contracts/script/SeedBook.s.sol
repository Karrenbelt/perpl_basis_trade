// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IKuruOrderBook, IKuruMarginAccount} from "../src/interfaces/IKuru.sol";
import {Mainnet} from "../test/Addresses.sol";

interface IKuruBookMaker {
    function addSellOrder(uint32 price, uint96 size, bool postOnly) external;
    function addBuyOrder(uint32 price, uint96 size, bool postOnly) external;
}

/// @notice Shared machinery for putting a resting order on a live Kuru book.
///
/// Dev tooling for a local fork. The live books almost never pay — that is the
/// whole point of the edge gate — so without a way to move them there is no way
/// to exercise the firing path end to end against real state.
///
/// Both directions have the same awkwardness: Kuru rejects a post-only order
/// that would cross, so before an order can rest at a price the opposing side
/// has to be cleared out from in front of it.
abstract contract SeedBook is Script {
    using SafeERC20 for IERC20;

    /// @dev Env: `PRIVATE_KEY` maker, `BOOK` orderbook, `PRICE_TICKS` target
    ///      price in the book's own precision, `SIZE` in its size precision.
    function _params() internal view returns (uint256 pk, address book, uint32 priceTicks, uint96 size) {
        pk = vm.envUint("PRIVATE_KEY");
        book = vm.envAddress("BOOK");
        priceTicks = uint32(vm.envUint("PRICE_TICKS"));
        size = uint96(vm.envUint("SIZE"));
    }

    function _fundMargin(address token, address maker, uint256 amount) internal {
        IERC20(token).forceApprove(Mainnet.KURU_MARGIN_ACCOUNT, amount);
        IKuruMarginAccount(Mainnet.KURU_MARGIN_ACCOUNT).deposit(maker, token, amount);
    }

    /// @dev The book quotes in 1e18 regardless of its own tick precision.
    function _targetWad(uint32 priceTicks, address book) internal view returns (uint256) {
        (uint32 pricePrecision,,,,,,,,,,) = IKuruOrderBook(book).getMarketParams();
        return uint256(priceTicks) * 1e18 / pricePrecision;
    }

    function _show(address book, string memory what) internal view {
        (uint256 bid, uint256 ask) = IKuruOrderBook(book).bestBidAsk();
        console2.log(what);
        console2.log("  bid", bid / 1e14);
        console2.log("  ask", ask / 1e14);
    }
}

/// @notice Rest a cheap ask: spot goes on offer below the perp, which is the
///         dislocation an entry is looking for.
contract SeedAsk is SeedBook {
    function run() external {
        (uint256 pk, address book, uint32 priceTicks, uint96 size) = _params();
        address base = vm.envAddress("TOKEN");
        address maker = vm.addr(pk);

        uint256 inventory = IERC20(base).balanceOf(maker);
        require(inventory >= uint256(size) * 4, "seed the maker with the base token first");
        uint256 target = _targetWad(priceTicks, book);

        vm.startBroadcast(pk);
        _fundMargin(base, maker, inventory);

        for (uint256 i; i < 12; ++i) {
            (uint256 bid,) = IKuruOrderBook(book).bestBidAsk();
            if (bid < target) break;
            IKuruOrderBook(book).placeAndExecuteMarketSell(size, 0, true, false);
        }

        IKuruBookMaker(book).addSellOrder(priceTicks, size, true);
        vm.stopBroadcast();

        _show(book, "ask rested");
    }
}

/// @notice Rest a bid: the mirror, so an unwind has something to sell into.
///         Seeding one at fair value is what "the basis converged" looks like.
contract SeedBid is SeedBook {
    function run() external {
        (uint256 pk, address book, uint32 priceTicks, uint96 size) = _params();
        address quote = vm.envAddress("TOKEN");
        address maker = vm.addr(pk);

        uint256 inventory = IERC20(quote).balanceOf(maker);
        require(inventory > 0, "seed the maker with the quote token first");
        uint256 target = _targetWad(priceTicks, book);

        vm.startBroadcast(pk);
        _fundMargin(quote, maker, inventory);

        for (uint256 i; i < 12; ++i) {
            (, uint256 ask) = IKuruOrderBook(book).bestBidAsk();
            if (ask > target) break;
            IKuruOrderBook(book).placeAndExecuteMarketBuy(uint96(500e6), 0, true, false);
        }

        IKuruBookMaker(book).addBuyOrder(priceTicks, size, true);
        vm.stopBroadcast();

        _show(book, "bid rested");
    }
}
