// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {AgentVault} from "../src/AgentVault.sol";
import {MockYieldSource} from "../src/adapters/MockYieldSource.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarket} from "./mocks/MockMarket.sol";

contract AgentVaultYieldTest is Test {
    AgentVault internal vault;
    MockYieldSource internal yieldSource;
    MockERC20 internal usdc;
    MockERC20 internal mon;
    MockMarket internal market;

    address internal creator = makeAddr("creator");
    address internal agentWallet = makeAddr("agentWallet");
    address internal custosCore = makeAddr("custosCore");
    address internal alice = makeAddr("alice");

    uint256 internal constant USDC = 1e6;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        mon = new MockERC20("Monad", "MON", 18);
        market = new MockMarket(address(mon), address(usdc), 2 * USDC, 1e18);
        mon.mint(address(market), 1_000_000 * 1e18);
        usdc.mint(address(market), 1_000_000 * USDC);

        yieldSource = new MockYieldSource(address(usdc), 500); // 5% APY

        vault = new AgentVault(
            keccak256("agent-yield"), creator, agentWallet, custosCore, address(usdc), address(market),
            address(yieldSource), 1000, 2000, 7000, 10_000 * uint128(USDC), 30 days,
            "Custos: agent-yield", "cst-ay"
        );

        vm.prank(custosCore);
        vault.setMarketAllowed(address(market), true);

        usdc.mint(alice, 1_000_000 * USDC);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    function test_pushToYieldAfterDeposit() public {
        vm.prank(alice);
        vault.deposit(1_000 * USDC, alice);

        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(yieldSource.balanceOf(address(vault)), 1_000 * USDC);
        assertEq(vault.totalAssets(), 1_000 * USDC);
    }

    function test_pullFromYieldBeforeSwap() public {
        vm.prank(alice);
        vault.deposit(1_000 * USDC, alice); // all pushed to yield, idle == 0

        vm.prank(agentWallet);
        vault.executeSwap(address(market), true, uint128(500 * USDC), 0, 0);

        // The swap needed 500 USDC of idle balance that wasn't there — it must have
        // come from yield, or the swap would have reverted for lack of funds.
        assertLt(yieldSource.balanceOf(address(vault)), 1_000 * USDC);
    }

    function test_yieldAccrualIncreasesSharePriceWithoutAnySwap() public {
        vm.prank(alice);
        vault.deposit(1_000 * USDC, alice);
        uint256 priceBefore = vault.totalAssets() * 1e18 / vault.totalSupply();

        vm.warp(block.timestamp + 365 days);
        uint256 priceAfter = vault.totalAssets() * 1e18 / vault.totalSupply();

        assertGt(priceAfter, priceBefore);
    }

    function test_pullFromYieldOnRedeem() public {
        vm.prank(alice);
        vault.deposit(1_000 * USDC, alice); // fully in yield, idle == 0

        vm.prank(alice);
        uint256 assets = vault.redeem(vault.balanceOf(alice), alice, alice);

        assertEq(assets, 1_000 * USDC);
        assertEq(usdc.balanceOf(alice), 1_000_000 * USDC); // back to starting balance
    }

    function test_feeChargedOnYieldProfit() public {
        vm.prank(alice);
        vault.deposit(10_000 * USDC, alice);

        vm.warp(block.timestamp + 365 days); // ~5% = 500 USDC of yield profit

        vm.prank(alice);
        vault.redeem(1, alice, alice); // any redeem call triggers _chargeFeeIfProfit first

        assertGt(vault.balanceOf(creator), 0);
    }

    function testFuzz_totalAssetsConsistency(uint256 depositAmount, uint256 warpSeconds) public {
        depositAmount = bound(depositAmount, 1 * USDC, 500_000 * USDC);
        warpSeconds = bound(warpSeconds, 0, 730 days);
        usdc.mint(alice, depositAmount);

        vm.prank(alice);
        usdc.approve(address(vault), depositAmount);
        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        vm.warp(block.timestamp + warpSeconds);

        uint256 idle = usdc.balanceOf(address(vault));
        uint256 inYield = yieldSource.balanceOf(address(vault));
        assertEq(vault.totalAssets(), idle + inYield);
    }
}
