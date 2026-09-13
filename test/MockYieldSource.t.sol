// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockYieldSource} from "../src/adapters/MockYieldSource.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract MockYieldSourceTest is Test {
    MockYieldSource internal yieldSource;
    MockERC20 internal usdc;
    address internal vault = makeAddr("vault");

    uint256 internal constant USDC = 1e6;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        // 5% annualized, matches spec's illustrative default.
        yieldSource = new MockYieldSource(address(usdc), 500);
        usdc.mint(vault, 1_000_000 * USDC);
    }

    function test_depositAndBalanceOfRoundTrip() public {
        vm.startPrank(vault);
        usdc.approve(address(yieldSource), 1_000 * USDC);
        yieldSource.deposit(1_000 * USDC);
        vm.stopPrank();

        assertEq(yieldSource.balanceOf(vault), 1_000 * USDC);
    }

    function test_balanceAccruesOverTime() public {
        vm.startPrank(vault);
        usdc.approve(address(yieldSource), 1_000 * USDC);
        yieldSource.deposit(1_000 * USDC);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        // 5% of 1000 USDC over exactly one year, plus/minus rounding.
        assertApproxEqAbs(yieldSource.balanceOf(vault), 1_050 * USDC, USDC / 100);
    }

    function test_withdrawReturnsPrincipalPlusYield() public {
        vm.startPrank(vault);
        usdc.approve(address(yieldSource), 1_000 * USDC);
        yieldSource.deposit(1_000 * USDC);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        vm.prank(vault);
        uint256 withdrawn = yieldSource.withdraw(500 * USDC);

        assertEq(withdrawn, 500 * USDC);
        assertApproxEqAbs(yieldSource.balanceOf(vault), 550 * USDC, USDC / 100);
    }

    function test_withdrawMoreThanBalanceCapsAtBalance() public {
        vm.startPrank(vault);
        usdc.approve(address(yieldSource), 1_000 * USDC);
        yieldSource.deposit(1_000 * USDC);
        uint256 withdrawn = yieldSource.withdraw(10_000 * USDC);
        vm.stopPrank();

        assertEq(withdrawn, 1_000 * USDC);
        assertEq(yieldSource.balanceOf(vault), 0);
    }
}
