// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Mainnet} from "./Addresses.sol";
import {IKuruOrderBook, IKuruMarginAccount} from "../src/interfaces/IKuru.sol";

interface IKuruBookMaker {
    function addSellOrder(uint32 price, uint96 size, bool postOnly) external;
    function addBuyOrder(uint32 price, uint96 size, bool postOnly) external;
}

/// @notice Shared fork setup for the integration tests.
/// @dev AUSD is an ERC1967 proxy whose balance mapping `deal` cannot locate, so
///      test capital is moved off a live holder instead of minted. That is the
///      more faithful source anyway - the balance arrives through the token's
///      own `transfer`, including whatever hooks it runs.
abstract contract ForkFixture is Test {
    using SafeERC20 for IERC20;

    address[] internal ausdWhales;

    function _forkMonad() internal {
        string memory rpc = vm.envString("MONAD_RPC_URL");
        uint256 forkBlock = vm.envOr("MONAD_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork(rpc, forkBlock);
        }

        ausdWhales.push(0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e);
        ausdWhales.push(0xE99f124109752f8e62B4fd5c7E3C01C1BBF58B24);
        ausdWhales.push(0xD1BFEA1728ffe98F515f26082fACfcc3341691D4);
        ausdWhales.push(0xD5D960E8C380B724a48AC59E2DfF1b2CB4a1eAee);
    }

    /// @notice Move `amount` AUSD to `to` from whichever live holder can cover it.
    function _fundAusd(address to, uint256 amount) internal {
        IERC20 ausd = IERC20(Mainnet.AUSD);
        for (uint256 i; i < ausdWhales.length; ++i) {
            address whale = ausdWhales[i];
            if (ausd.balanceOf(whale) >= amount) {
                vm.prank(whale);
                ausd.safeTransfer(to, amount);
                return;
            }
        }
        revert("no AUSD whale holds enough at this fork block");
    }

    /// @notice Put a cheap resting ask on `book`, the condition the strategy
    ///         exists to catch.
    /// @dev A post-only ask under the current bid is rejected, so the seeded
    ///      maker first sells into the bid until it is out of the way. The real
    ///      books are thin enough that a few hundredths of a coin does it -
    ///      which is itself worth knowing about these markets.
    /// @param priceTicks Ask price in the market's own price precision.
    /// @param size Order size in the market's own size precision.
    function _seedCheapAsk(address book, address baseToken, uint32 priceTicks, uint96 size) internal {
        address maker = makeAddr("kuruMaker");
        uint256 inventory = uint256(size) * 20;
        deal(baseToken, maker, inventory);

        vm.startPrank(maker);
        IERC20(baseToken).approve(Mainnet.KURU_MARGIN_ACCOUNT, inventory);
        IKuruMarginAccount(Mainnet.KURU_MARGIN_ACCOUNT).deposit(maker, baseToken, inventory);

        // Clear the bid out from under the price we want to rest at.
        for (uint256 i; i < 10; ++i) {
            (uint256 bid,) = IKuruOrderBook(book).bestBidAsk();
            if (bid < uint256(priceTicks) * 1e18 / 1e4) break;
            IKuruOrderBook(book).placeAndExecuteMarketSell(size, 0, true, false);
        }

        IKuruBookMaker(book).addSellOrder(priceTicks, size, true);
        vm.stopPrank();
    }

    /// @notice Put a rich resting bid on `book` so an unwind has something good
    ///         to sell into.
    /// @dev The mirror of `_seedCheapAsk`: a post-only bid above the current ask
    ///      is rejected, so the maker first lifts every ask under the target out
    ///      of the way.
    function _seedRichBid(address book, address quoteToken, uint32 priceTicks, uint96 size) internal {
        address maker = makeAddr("kuruBidder");
        uint256 inventory = 500_000e6;
        deal(quoteToken, maker, inventory);

        vm.startPrank(maker);
        IERC20(quoteToken).approve(Mainnet.KURU_MARGIN_ACCOUNT, inventory);
        IKuruMarginAccount(Mainnet.KURU_MARGIN_ACCOUNT).deposit(maker, quoteToken, inventory);

        uint256 target = uint256(priceTicks) * 1e18 / 1e4;
        for (uint256 i; i < 12; ++i) {
            (, uint256 ask) = IKuruOrderBook(book).bestBidAsk();
            if (ask > target) break;
            IKuruOrderBook(book).placeAndExecuteMarketBuy(uint96(500e6), 0, true, false);
        }

        IKuruBookMaker(book).addBuyOrder(priceTicks, size, true);
        vm.stopPrank();
    }
}
