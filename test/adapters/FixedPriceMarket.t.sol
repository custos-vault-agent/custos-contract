// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {FixedPriceMarket} from "../../src/adapters/FixedPriceMarket.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract FixedPriceMarketTest is Test {
    uint256 internal constant USDC = 1e6;
    uint256 internal constant MON = 1e18;

    MockERC20 internal usdc;
    MockERC20 internal mon;
    FixedPriceMarket internal market;
    address internal owner = makeAddr("owner");
    address internal trader = makeAddr("trader");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        mon = new MockERC20("Monad", "MON", 18);

        vm.prank(owner);
        market = new FixedPriceMarket(address(mon), address(usdc), 2 * USDC, 1 * MON);

        mon.mint(address(market), 1_000 * MON);
        usdc.mint(address(market), 1_000 * USDC);
    }

    function test_buy_convertsQuoteToBaseAtPrice() public {
        usdc.mint(trader, 100 * USDC);
        vm.startPrank(trader);
        usdc.approve(address(market), 100 * USDC);
        uint256 out = market.swap(true, 100 * USDC, 0);
        vm.stopPrank();

        assertEq(out, 50 * MON); // 100 USDC / (2 USDC per MON) = 50 MON
        assertEq(mon.balanceOf(trader), 50 * MON);
    }

    function test_sell_convertsBaseToQuoteAtPrice() public {
        mon.mint(trader, 10 * MON);
        vm.startPrank(trader);
        mon.approve(address(market), 10 * MON);
        uint256 out = market.swap(false, 10 * MON, 0);
        vm.stopPrank();

        assertEq(out, 20 * USDC); // 10 MON * 2 USDC per MON
        assertEq(usdc.balanceOf(trader), 20 * USDC);
    }

    function test_swap_revertsOnSlippage() public {
        usdc.mint(trader, 100 * USDC);
        vm.startPrank(trader);
        usdc.approve(address(market), 100 * USDC);
        vm.expectRevert(FixedPriceMarket.MarketSlippage.selector);
        market.swap(true, 100 * USDC, 51 * MON);
        vm.stopPrank();
    }

    function test_setPrice_onlyOwner() public {
        vm.prank(trader);
        vm.expectRevert(FixedPriceMarket.NotOwner.selector);
        market.setPrice(3 * USDC, 1 * MON);

        vm.prank(owner);
        market.setPrice(3 * USDC, 1 * MON);
        assertEq(market.priceNum(), 3 * USDC);
    }
}
