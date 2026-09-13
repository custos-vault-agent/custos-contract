// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {MockYieldSource} from "../src/adapters/MockYieldSource.sol";
import {Status} from "../src/Types.sol";

contract IntegrationTest is Base {
    function _registerWithYield(uint16 maxDrawdownBps, uint128 seedAmount)
        internal
        returns (bytes32 id, address vault, MockYieldSource yieldSource)
    {
        yieldSource = new MockYieldSource(address(usdc), 500); // 5% APY
        // MockYieldSource only ever holds the principal it's deposited — it computes
        // accrued interest as a view, but never receives the extra USDC needed to pay
        // it out. A real lending protocol has genuine yield behind it; this fake one
        // needs a reserve funded up front so a real withdrawal after real elapsed
        // time doesn't revert insolvent (only matters here — existing unit tests
        // never warp far enough while also withdrawing the full balance).
        usdc.mint(address(yieldSource), 1_000_000 * USDC);

        usdc.mint(alice, seedAmount);
        vm.prank(alice);
        usdc.approve(address(custos), seedAmount);

        vm.prank(alice);
        (id, vault) = custos.registerAgent(
            bytes32("full-flow"), "d", agentWallet, 100_000 * uint128(USDC), 30 days, 1000, maxDrawdownBps,
            address(yieldSource), 7000, true, seedAmount
        );

        vm.prank(authority);
        custos.setMarketAllowed(id, address(market), true);
    }

    function test_fullFlow() public {
        (, address vault, MockYieldSource yieldSource) = _registerWithYield(2000, 1_000 * uint128(USDC));

        // Yield accrues on the seed alone before anyone else shows up.
        vm.warp(block.timestamp + 30 days);

        usdc.mint(bob, 10_000 * USDC);
        vm.prank(bob);
        usdc.approve(vault, 10_000 * USDC);
        vm.prank(bob);
        AgentVault(vault).deposit(10_000 * USDC, bob);
        assertGt(yieldSource.balanceOf(vault), 0);

        // Agent trades profitably: pulls from yield, swaps, pushes idle back.
        vm.prank(agentWallet);
        AgentVault(vault).executeSwap(address(market), true, uint128(2_000 * USDC), 0, 0);
        uint256 monBal = mon.balanceOf(vault);
        market.setPayoutBps(11_000); // sell back at a 10% better rate — net profit
        vm.prank(agentWallet);
        AgentVault(vault).executeSwap(address(market), false, uint128(monBal), 0, uint128(3_000 * USDC));

        uint256 creatorSharesBeforeRedeem = AgentVault(vault).balanceOf(alice);

        uint256 bobShares = AgentVault(vault).balanceOf(bob);
        vm.prank(bob);
        uint256 assetsOut = AgentVault(vault).redeem(bobShares, bob, bob);

        // Bob's redemption may itself trigger one more fee charge (yield kept
        // accruing since the swap) — the property that matters is creator ends up
        // with at least as many shares as right after the profitable round-trip,
        // and Bob got real USDC back.
        assertGe(AgentVault(vault).balanceOf(alice), creatorSharesBeforeRedeem);
        assertGt(assetsOut, 0);
    }

    function test_fullFlowWithCircuitBreaker() public {
        (bytes32 id, address vault, MockYieldSource yieldSource) = _registerWithYield(1000, 10_000 * uint128(USDC));

        usdc.mint(bob, 10_000 * USDC);
        vm.prank(bob);
        usdc.approve(vault, 10_000 * USDC);
        vm.prank(bob);
        AgentVault(vault).deposit(10_000 * USDC, bob); // vault now 20,000 USDC total

        // A 12% drawdown against a 10% threshold: buy 2,400 of 20,000 (12%).
        vm.prank(agentWallet);
        AgentVault(vault).executeSwap(address(market), true, uint128(2_400 * USDC), 0, 0);
        assertEq(uint8(AgentVault(vault).status()), uint8(Status.Paused));

        vm.prank(agentWallet);
        vm.expectRevert(); // VaultNotActive
        AgentVault(vault).executeSwap(address(market), true, uint128(1 * USDC), 0, 0);

        // Bob can still redeem — pulling from yield if idle balance is short.
        uint256 bobShares = AgentVault(vault).balanceOf(bob);
        vm.prank(bob);
        uint256 assetsOut = AgentVault(vault).redeem(bobShares, bob, bob);
        assertGt(assetsOut, 0);

        vm.prank(alice);
        custos.resumeAgent(id);
        assertEq(uint8(AgentVault(vault).status()), uint8(Status.Active));

        vm.prank(agentWallet);
        AgentVault(vault).executeSwap(address(market), true, uint128(100 * USDC), 0, 0);
        assertEq(uint8(AgentVault(vault).status()), uint8(Status.Active));

        yieldSource; // silence unused-variable warning if the compiler flags it
    }

    function test_creatorOnlyNoSubscriber() public {
        (, address vault, MockYieldSource yieldSource) = _registerWithYield(2000, 5_000 * uint128(USDC));

        vm.warp(block.timestamp + 180 days); // yield accrues with zero subscribers
        uint256 priceAfterYield = (AgentVault(vault).totalAssets() * 1e18) / AgentVault(vault).totalSupply();
        assertGt(priceAfterYield, 1e18);

        // Creator adds more of their own capital, beyond the locked seed.
        usdc.mint(alice, 5_000 * USDC);
        vm.prank(alice);
        usdc.approve(vault, 5_000 * USDC);
        vm.prank(alice);
        AgentVault(vault).deposit(5_000 * USDC, alice);

        vm.prank(agentWallet);
        AgentVault(vault).executeSwap(address(market), true, uint128(1_000 * USDC), 0, 0);
        market.setPayoutBps(11_000);
        uint256 monBal = mon.balanceOf(vault);
        vm.prank(agentWallet);
        AgentVault(vault).executeSwap(address(market), false, uint128(monBal), 0, uint128(1_500 * USDC));

        // No subscriber ever showed up — only the seed (locked, address(1)) and
        // alice's own extra deposit hold shares. Her deposit landed after 180 days
        // of accrual already pushed the share price above 1:1, so her share COUNT
        // is naturally below 5,000 (each share cost more than 1 USDC) — what should
        // grow past her principal is the ASSET VALUE those shares redeem for, once
        // the profitable round-trip after her deposit adds more alpha on top.
        assertEq(AgentVault(vault).balanceOf(bob), 0);
        assertGt(AgentVault(vault).previewRedeem(AgentVault(vault).balanceOf(alice)), 5_000 * uint128(USDC));

        yieldSource;
    }
}
