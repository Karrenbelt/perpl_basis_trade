// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForkFixture} from "./Fixtures.sol";
import {Mainnet} from "./Addresses.sol";
import {IKuruRouter} from "../src/interfaces/IKuru.sol";

/// @notice Characterises how much size the live books actually absorb.
/// @dev Not an assertion suite - it is the measurement that set the trade sizes
///      the rest of the tests use, and the reason the executor caps notional per
///      market. Run it when the venues change.
contract VenueDepthTest is ForkFixture {
    function setUp() public {
        _forkMonad();
    }

    function _try(address book, bool buy, address tin, address tout, uint256 amt)
        internal
        returns (bool ok, uint256 out)
    {
        uint256 snap = vm.snapshotState();
        address[] memory route = new address[](1);
        route[0] = book;
        bool[] memory isBuy = new bool[](1);
        isBuy[0] = buy;
        bool[] memory ns = new bool[](1);
        IERC20(tin).approve(Mainnet.KURU_ROUTER, amt);
        try IKuruRouter(Mainnet.KURU_ROUTER).anyToAnySwap(route, isBuy, ns, tin, tout, amt, 0) returns (
            uint256 o
        ) {
            ok = true;
            out = IERC20(tout).balanceOf(address(this));
            o;
        } catch (bytes memory err) {
            ok = false;
            console2.logBytes(err);
        }
        vm.revertToState(snap);
    }

    function test_ausdUsdcDepth() public {
        address[3] memory books = [
            0x699AbC15308156E9a3AB89Ec7387e9CfE1c86A3b,
            0x8cF49e35D73B19433FF4d4421637AABB680dc9Cc,
            0xb0cb296f980573BfF4F45df0d392541D497172cC
        ];
        uint256[5] memory sizes = [uint256(50e6), 200e6, 1_000e6, 5_000e6, 20_000e6];
        _fundAusd(address(this), 50_000e6);
        for (uint256 i; i < books.length; ++i) {
            for (uint256 j; j < sizes.length; ++j) {
                (bool ok, uint256 out) = _try(books[i], false, Mainnet.AUSD, Mainnet.USDC, sizes[j]);
                console2.log("AUSD/USDC book", i, "size", sizes[j]);
                console2.log("   ok", ok, "usdcOut", out);
            }
        }
    }

    function test_cbbtcDepth() public {
        uint256[5] memory sizes = [uint256(50e6), 200e6, 1_000e6, 5_000e6, 20_000e6];
        deal(Mainnet.USDC, address(this), 50_000e6);
        for (uint256 j; j < sizes.length; ++j) {
            (bool ok, uint256 out) =
                _try(Mainnet.BOOK_CBBTC_USDC, true, Mainnet.USDC, Mainnet.CBBTC, sizes[j]);
            console2.log("cbBTC size", sizes[j]);
            console2.log("   ok", ok, "cbbtcOut", out);
        }
    }

    function test_wethMonDepth() public {
        uint256[4] memory sizes = [uint256(50e6), 200e6, 1_000e6, 5_000e6];
        deal(Mainnet.USDC, address(this), 50_000e6);
        for (uint256 j; j < sizes.length; ++j) {
            (bool ok, uint256 out) = _try(Mainnet.BOOK_WETH_USDC, true, Mainnet.USDC, Mainnet.WETH, sizes[j]);
            console2.log("WETH size", sizes[j]);
            console2.log("   ok", ok, "wethOut", out);
        }
    }
}
