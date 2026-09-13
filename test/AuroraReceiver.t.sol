// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {NotAuroraReceiver, Paused, UnknownAgent} from "../src/Errors.sol";

contract AuroraReceiverTest is Base {
    function test_creditDepositMintsSharesToSubscriber() public {
        (bytes32 id, address vault) = _registerAgent(alice, agentWallet, 4_000 * uint128(USDC), 1 days);

        usdc.mint(auroraReceiver, 1_000 * USDC);
        vm.prank(auroraReceiver);
        usdc.approve(address(custos), 1_000 * USDC);

        vm.prank(auroraReceiver);
        uint256 shares = custos.creditDeposit(id, bob, 1_000 * USDC);

        assertEq(shares, 1_000 * USDC);
        assertEq(AgentVault(vault).balanceOf(bob), 1_000 * USDC);
    }

    function test_creditDepositOnlyAuroraReceiver() public {
        (bytes32 id,) = _registerAgent(alice, agentWallet, 4_000 * uint128(USDC), 1 days);

        vm.prank(alice);
        vm.expectRevert(NotAuroraReceiver.selector);
        custos.creditDeposit(id, bob, 1_000 * USDC);
    }

    function test_creditDepositRevertsForUnknownAgent() public {
        vm.prank(auroraReceiver);
        vm.expectRevert(UnknownAgent.selector);
        custos.creditDeposit(bytes32("nope"), bob, 1_000 * USDC);
    }

    function test_creditDepositBlockedWhenPaused() public {
        (bytes32 id,) = _registerAgent(alice, agentWallet, 4_000 * uint128(USDC), 1 days);

        vm.prank(authority);
        custos.pause();

        vm.prank(auroraReceiver);
        vm.expectRevert(Paused.selector);
        custos.creditDeposit(id, bob, 1_000 * USDC);
    }
}
