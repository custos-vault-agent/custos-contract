// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {AgentVault} from "../src/AgentVault.sol";
import {Status} from "../src/Types.sol";
import {
    AgentCannotCallThis, MarketNotAllowed, VaultNotActive, ZeroAmount
} from "../src/Errors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarket} from "./mocks/MockMarket.sol";

contract AgentVaultTest is Test {
    AgentVault internal vault;
    MockERC20 internal usdc;
    MockERC20 internal mon;
    MockMarket internal market;

    address internal creator = makeAddr("creator");
    address internal agentWallet = makeAddr("agentWallet");
    address internal custosCore = makeAddr("custosCore");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant USDC = 1e6;
    uint256 internal constant MON = 1e18;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        mon = new MockERC20("Monad", "MON", 18);
        market = new MockMarket(address(mon), address(usdc), 2 * USDC, 1 * MON);

        vault = new AgentVault(
            keccak256("agent-1"),
            creator,
            agentWallet,
            custosCore,
            address(usdc),
            address(market), // marketAdapter — MockMarket doubles as IMarket here
            address(0), // yieldSource disabled for this test
            1000, // feeRate 10%
            2000, // maxDrawdownBps 20%
            7000, // maxUtilizationBps 70%
            10_000 * uint128(USDC), // allowance
            30 days, // periodLength
            "Custos: agent-1",
            "cst-a1"
        );

        usdc.mint(alice, 100_000 * USDC);
        usdc.mint(bob, 100_000 * USDC);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    function test_immutablesSetCorrectly() public view {
        assertEq(vault.creator(), creator);
        assertEq(vault.agent(), agentWallet);
        assertEq(vault.custosCore(), custosCore);
        assertEq(vault.agentId(), keccak256("agent-1"));
        assertEq(vault.feeRate(), 1000);
        assertEq(vault.maxDrawdownBps(), 2000);
        assertEq(vault.maxUtilizationBps(), 7000);
        assertEq(uint8(vault.status()), uint8(Status.Active));
    }

    function test_depositMintsSharesAtOnePerOne() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1_000 * USDC, alice);

        assertEq(shares, 1_000 * USDC);
        assertEq(vault.balanceOf(alice), 1_000 * USDC);
        assertEq(vault.totalAssets(), 1_000 * USDC);
    }

    function test_multipleDepositorsGetProportionalShares() public {
        vm.prank(alice);
        vault.deposit(1_000 * USDC, alice);
        vm.prank(bob);
        vault.deposit(2_000 * USDC, bob);

        assertEq(vault.balanceOf(alice), 1_000 * USDC);
        assertEq(vault.balanceOf(bob), 2_000 * USDC);
        assertEq(vault.totalAssets(), 3_000 * USDC);
    }

    function test_redeemReturnsProportionalAssets() public {
        vm.prank(alice);
        vault.deposit(1_000 * USDC, alice);

        vm.prank(alice);
        uint256 assets = vault.redeem(500 * USDC, alice, alice);

        assertEq(assets, 500 * USDC);
        assertEq(usdc.balanceOf(alice), 100_000 * USDC - 500 * USDC);
    }

    function test_withdrawBurnsCorrectShares() public {
        vm.prank(alice);
        vault.deposit(1_000 * USDC, alice);

        vm.prank(alice);
        uint256 shares = vault.withdraw(400 * USDC, alice, alice);

        assertEq(shares, 400 * USDC);
        assertEq(vault.balanceOf(alice), 600 * USDC);
    }

    function test_depositRevertsWhenPaused() public {
        vm.prank(custosCore);
        vault.setStatus(Status.Paused);

        vm.prank(alice);
        vm.expectRevert(VaultNotActive.selector);
        vault.deposit(1_000 * USDC, alice);
    }

    function test_mintRevertsWhenPaused() public {
        vm.prank(custosCore);
        vault.setStatus(Status.Paused);

        vm.prank(alice);
        vm.expectRevert(VaultNotActive.selector);
        vault.mint(1_000 * USDC, alice);
    }

    function test_redeemWorksWhilePaused() public {
        vm.prank(alice);
        vault.deposit(1_000 * USDC, alice);

        vm.prank(custosCore);
        vault.setStatus(Status.Paused);

        vm.prank(alice);
        uint256 assets = vault.redeem(500 * USDC, alice, alice);
        assertEq(assets, 500 * USDC);
    }

    function test_agentCannotDeposit() public {
        vm.prank(agentWallet);
        vm.expectRevert(AgentCannotCallThis.selector);
        vault.deposit(1 * USDC, agentWallet);
    }

    function test_agentCannotRedeem() public {
        vm.prank(alice);
        vault.deposit(1_000 * USDC, alice);

        vm.prank(agentWallet);
        vm.expectRevert(AgentCannotCallThis.selector);
        vault.redeem(1, agentWallet, alice);
    }

    function test_agentCannotTransferShares() public {
        vm.prank(alice);
        vault.deposit(1_000 * USDC, alice);
        vm.prank(alice);
        vault.transfer(agentWallet, 100 * USDC);

        vm.prank(agentWallet);
        vm.expectRevert(AgentCannotCallThis.selector);
        vault.transfer(bob, 1);
    }

    function test_onlyCustosCoreCanSetStatus() public {
        vm.prank(alice);
        vm.expectRevert(); // OnlyCustosCore
        vault.setStatus(Status.Paused);
    }

    /* --------------------------------- Task 9 -------------------------------- */

    function _allowMarket() internal {
        vm.prank(custosCore);
        vault.setMarketAllowed(address(market), true);
    }

    function test_onlyAgentCanExecuteSwap() public {
        _allowMarket();
        vm.prank(alice);
        vault.deposit(10_000 * USDC, alice);

        vm.prank(alice);
        vm.expectRevert(); // OnlyAgent
        vault.executeSwap(address(market), true, uint128(1_000 * USDC), 0, 0);
    }

    function test_swapRevertsOnUnallowedMarket() public {
        vm.prank(alice);
        vault.deposit(10_000 * USDC, alice);

        vm.prank(agentWallet);
        vm.expectRevert(MarketNotAllowed.selector);
        vault.executeSwap(address(market), true, uint128(1_000 * USDC), 0, 0);
    }

    function test_sellWithoutMaxNotionalReverts() public {
        _allowMarket();
        vm.prank(alice);
        vault.deposit(10_000 * USDC, alice);

        vm.prank(agentWallet);
        vm.expectRevert(ZeroAmount.selector);
        vault.executeSwap(address(market), false, uint128(1 * MON), 0, 0);
    }

    function test_allowanceConsumedCorrectly() public {
        _allowMarket();
        vm.prank(alice);
        vault.deposit(10_000 * USDC, alice); // allowance is 10,000 USDC (constructor), well under 70% of 10,000

        vm.prank(agentWallet);
        vault.executeSwap(address(market), true, uint128(1_000 * USDC), 0, 0);

        assertEq(vault.usedInPeriod(), 1_000 * USDC);
    }

    function test_swapUpdatesSharePrice() public {
        _allowMarket();
        vm.prank(alice);
        vault.deposit(10_000 * USDC, alice);
        uint256 priceBefore = vault.totalAssets() * 1e18 / vault.totalSupply();

        vm.prank(agentWallet);
        vault.executeSwap(address(market), true, uint128(1_000 * USDC), 0, 0);
        uint256 priceAfter = vault.totalAssets() * 1e18 / vault.totalSupply();

        // totalAssets() only counts the accounting asset (USDC) + yield position —
        // MON received from the buy sits in the vault as an untracked asset for now,
        // so a pure buy looks like a loss until it's sold back. That is itself worth
        // asserting: it is the reason `totalAssets` must stay denominated in one
        // asset (D4), never mark-to-market a base token position.
        assertLt(priceAfter, priceBefore);
    }

    function test_reserveRatioCapsTrading() public {
        _allowMarket();
        vm.prank(alice);
        vault.deposit(100_000 * USDC, alice); // maxUtilizationBps = 7000 → cap 70,000

        vm.prank(agentWallet);
        vm.expectRevert(); // AllowanceExceeded
        vault.executeSwap(address(market), true, uint128(80_000 * USDC), 0, 0);

        vm.prank(agentWallet);
        vault.executeSwap(address(market), true, uint128(60_000 * USDC), 0, 0); // under 70k, succeeds
    }

    function test_reserveRatioScalesWithDeposits() public {
        _allowMarket();
        vm.prank(alice);
        vault.deposit(10_000 * USDC, alice);
        vm.prank(bob);
        vault.deposit(90_000 * USDC, bob); // vault now 100,000 → 70% = 70,000

        vm.prank(agentWallet);
        vault.executeSwap(address(market), true, uint128(65_000 * USDC), 0, 0); // fits now
    }

    function test_reserveEnsuresRedeemability() public {
        _allowMarket();
        vm.prank(alice);
        vault.deposit(100_000 * USDC, alice);

        vm.prank(agentWallet);
        vault.executeSwap(address(market), true, uint128(70_000 * USDC), 0, 0); // uses full 70%

        // The 30% reserve (30,000 USDC) was never touched by the swap — a redeem of
        // up to that share of the vault must succeed without needing anything back
        // from the agent's position.
        vm.prank(alice);
        uint256 assets = vault.redeem(vault.balanceOf(alice) * 3 / 10, alice, alice);
        assertGt(assets, 0);
    }

    /* -------------------------------- Task 11 -------------------------------- */

    function test_feeMintsSharesOnProfit() public {
        vm.prank(alice);
        vault.deposit(10_000 * USDC, alice);

        usdc.mint(address(vault), 1_000 * USDC); // profit, any source

        vm.prank(alice);
        vault.redeem(1, alice, alice); // triggers _chargeFeeIfProfit

        assertGt(vault.balanceOf(creator), 0);
    }

    function test_noFeeWhenBelowHighWaterMark() public {
        vm.prank(alice);
        vault.deposit(10_000 * USDC, alice);
        // No profit injected — share price sits exactly at the high water mark.

        vm.prank(alice);
        vault.redeem(1, alice, alice);

        assertEq(vault.balanceOf(creator), 0);
    }

    function test_highWaterMarkOnlyGoesUp() public {
        vm.prank(alice);
        vault.deposit(10_000 * USDC, alice);
        usdc.mint(address(vault), 1_000 * USDC);

        vm.prank(alice);
        vault.redeem(1, alice, alice);
        uint256 hwmAfterProfit = vault.highWaterMark();

        // A second redeem with no new profit must not move it — this is the
        // property Task 12's circuit-breaker-resume exception (the only sanctioned
        // way HWM ever falls) has to be measured against.
        vm.prank(alice);
        vault.redeem(1, alice, alice);
        assertEq(vault.highWaterMark(), hwmAfterProfit);
    }

    function test_doubleDipPrevented() public {
        vm.prank(alice);
        vault.deposit(10_000 * USDC, alice);
        usdc.mint(address(vault), 1_000 * USDC);

        vm.prank(alice);
        vault.redeem(1, alice, alice);
        uint256 creatorSharesAfterFirstFee = vault.balanceOf(creator);

        // No new profit between these two redeems — a second fee charge here would
        // be exactly what "double dip" looks like.
        vm.prank(alice);
        vault.redeem(1, alice, alice);
        assertEq(vault.balanceOf(creator), creatorSharesAfterFirstFee);
    }

    function testFuzz_feeNeverExceedsProfitRatio(uint256 depositAmount, uint256 profitAmount) public {
        depositAmount = bound(depositAmount, 100 * USDC, 1_000_000 * USDC);
        profitAmount = bound(profitAmount, 1, depositAmount);
        usdc.mint(alice, depositAmount);
        vm.prank(alice);
        usdc.approve(address(vault), depositAmount);
        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        usdc.mint(address(vault), profitAmount);

        uint256 creatorSharesBefore = vault.balanceOf(creator);
        vm.prank(alice);
        vault.redeem(1, alice, alice);
        uint256 feeShares = vault.balanceOf(creator) - creatorSharesBefore;
        uint256 feeAssets = vault.convertToAssets(feeShares);

        // feeRate is 1000 bps (10%) in this fixture's constructor (Task 5's setUp).
        assertLe(feeAssets, (profitAmount * 1000) / 10_000 + 2); // +2 for rounding slack
    }
}
