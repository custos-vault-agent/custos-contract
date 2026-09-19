// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {MockAuroraReceiver} from "./mocks/MockAuroraReceiver.sol";

/// @notice Sisi lain dari `AuroraReceiverTest`: bukan `creditDeposit` dipanggil
///         langsung oleh sebuah EOA yang di-allowlist, tapi lewat kontrak yang
///         menempati posisi Aurora Receiver sungguhan — jalur yang dipakai demo
///         "deposit dari chain manapun" selama Aurora Intents Connect belum punya
///         endpoint testnet.
contract AuroraIntentMockTest is Base {
    MockAuroraReceiver internal mockReceiver;

    function setUp() public override {
        super.setUp();
        mockReceiver = new MockAuroraReceiver(custos, usdc);

        vm.prank(authority);
        custos.setAuroraReceiver(address(mockReceiver));
    }

    function test_fulfillIntentCreditsSharesToSubscriber() public {
        (bytes32 id, address vault) = _registerAgent(alice, agentWallet, uint128(4_000 * USDC), 1 days);

        // Stand-in for "the solver already bridged and swapped funds to this
        // chain": bob's wallet already holds accounting-asset USDC before the
        // intent is fulfilled.
        usdc.mint(bob, 1_000 * USDC);
        vm.prank(bob);
        usdc.approve(address(mockReceiver), 1_000 * USDC);

        vm.prank(bob);
        uint256 shares = mockReceiver.fulfillIntent(id, bob, 1_000 * USDC);

        assertEq(shares, 1_000 * USDC);
        assertEq(AgentVault(vault).balanceOf(bob), 1_000 * USDC);
        assertEq(usdc.balanceOf(address(mockReceiver)), 0);
    }
}
