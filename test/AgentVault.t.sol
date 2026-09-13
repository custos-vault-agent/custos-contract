// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {AgentVault} from "../src/AgentVault.sol";
import {Status} from "../src/Types.sol";
import {AgentCannotCallThis, VaultNotActive} from "../src/Errors.sol";
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
}
