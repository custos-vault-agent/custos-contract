// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {Agent, Status} from "../src/Types.sol";
import {
    AgentAlreadyRevoked,
    AllowanceExceeded,
    InsufficientAvailable,
    NotAgentOwner,
    SelfDelegation,
    TooManyAgents,
    UnknownAgent,
    WalletAlreadyBound
} from "../src/Errors.sol";

contract AgentCoreTest is Base {
    function test_register() public {
        _deposit(alice, usdc, 1_000 * USDC);
        bytes32 id = _registerAgent(alice, agentWallet, uint128(600 * USDC), 30 days);

        Agent memory a = custos.getAgent(id);
        assertEq(a.owner, alice);
        assertEq(a.wallet, agentWallet);
        assertEq(uint8(a.status), uint8(Status.Active));
        assertEq(a.allowance, 600 * USDC);
        assertEq(a.periodLength, 30 days);
        assertEq(a.descriptionHash, keccak256(bytes("trading bot")));

        assertEq(custos.agentIdOf(agentWallet), id);
        assertEq(custos.delegatedOf(alice), 600 * USDC);
        assertEq(custos.availableOf(alice), 400 * USDC);
        assertEq(custos.agentCount(), 1);
    }

    /// @notice Allowance harus tertutup saldo yang benar-benar ada; kalau tidak, ia hanya
    ///         angka di layar.
    function test_cannotDelegateMoreThanBalance() public {
        _deposit(alice, usdc, 100 * USDC);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientAvailable.selector, 100 * USDC));
        custos.registerAgent(bytes32("bot"), "d", agentWallet, uint128(101 * USDC), 0);
    }

    /// @notice Ikatan wallet permanen (D8) — bahkan setelah dicabut, dan bahkan untuk
    ///         owner yang berbeda.
    function test_walletCannotBeReregistered() public {
        _deposit(alice, usdc, 1_000 * USDC);
        _deposit(bob, usdc, 1_000 * USDC);
        bytes32 id = _registerAgent(alice, agentWallet, uint128(100 * USDC), 0);

        vm.prank(alice);
        custos.revokeAgent(id);

        vm.prank(alice);
        vm.expectRevert(WalletAlreadyBound.selector);
        custos.registerAgent(bytes32("bot"), "d", agentWallet, uint128(100 * USDC), 0);

        vm.prank(bob);
        vm.expectRevert(WalletAlreadyBound.selector);
        custos.registerAgent(bytes32("bot"), "d", agentWallet, uint128(100 * USDC), 0);
    }

    function test_cannotRegisterSelf() public {
        _deposit(alice, usdc, 1_000 * USDC);
        vm.prank(alice);
        vm.expectRevert(SelfDelegation.selector);
        custos.registerAgent(bytes32("bot"), "d", alice, uint128(100 * USDC), 0);
    }

    function test_onlyOwnerCanManage() public {
        _deposit(alice, usdc, 1_000 * USDC);
        bytes32 id = _registerAgent(alice, agentWallet, uint128(100 * USDC), 0);

        vm.startPrank(bob);
        vm.expectRevert(NotAgentOwner.selector);
        custos.setAllowance(id, 0);
        vm.expectRevert(NotAgentOwner.selector);
        custos.pauseAgent(id);
        vm.expectRevert(NotAgentOwner.selector);
        custos.revokeAgent(id);
        vm.stopPrank();
    }

    /// @notice Agent tidak boleh punya jalur untuk menaikkan batasnya sendiri.
    function test_agentCannotManageItself() public {
        _deposit(alice, usdc, 1_000 * USDC);
        bytes32 id = _registerAgent(alice, agentWallet, uint128(100 * USDC), 0);

        vm.prank(agentWallet);
        vm.expectRevert(NotAgentOwner.selector);
        custos.setAllowance(id, uint128(1_000 * USDC));
    }

    function test_unknownAgentReverts() public {
        vm.prank(alice);
        vm.expectRevert(UnknownAgent.selector);
        custos.pauseAgent(bytes32("nope"));
    }

    function test_pauseFreesDelegationAndResumeTakesItBack() public {
        _deposit(alice, usdc, 1_000 * USDC);
        bytes32 id = _registerAgent(alice, agentWallet, uint128(600 * USDC), 0);

        vm.prank(alice);
        custos.pauseAgent(id);
        assertEq(custos.delegatedOf(alice), 0);
        assertEq(custos.availableOf(alice), 1_000 * USDC);

        vm.prank(alice);
        custos.resumeAgent(id);
        assertEq(custos.availableOf(alice), 400 * USDC);
    }

    /// @notice Owner bisa menarik dana selagi agent tidur. Melanjutkannya lalu harus
    ///         gagal, bukan diam-diam mengecilkan allowance — perubahan batas selalu
    ///         keputusan eksplisit owner.
    function test_resumeRevertsIfOwnerWithdrewMeanwhile() public {
        _deposit(alice, usdc, 1_000 * USDC);
        bytes32 id = _registerAgent(alice, agentWallet, uint128(600 * USDC), 0);

        vm.startPrank(alice);
        custos.pauseAgent(id);
        custos.withdraw(address(usdc), 900 * USDC);

        vm.expectRevert(abi.encodeWithSelector(InsufficientAvailable.selector, 100 * USDC));
        custos.resumeAgent(id);
        vm.stopPrank();

        // Agent tetap tertidur, dan delegasinya tetap nol.
        assertEq(uint8(custos.getAgent(id).status), uint8(Status.Paused));
        assertEq(custos.delegatedOf(alice), 0);
    }

    function test_revokeIsPermanent() public {
        _deposit(alice, usdc, 1_000 * USDC);
        bytes32 id = _registerAgent(alice, agentWallet, uint128(600 * USDC), 0);

        vm.startPrank(alice);
        custos.revokeAgent(id);
        vm.expectRevert(AgentAlreadyRevoked.selector);
        custos.revokeAgent(id);
        vm.stopPrank();

        assertEq(custos.delegatedOf(alice), 0);
        // Hilang dari daftar agent hidup, tetap ada di direktori publik.
        assertEq(custos.agentsOfOwner(alice).length, 0);
        assertEq(custos.agentCount(), 1);
        assertEq(custos.getAgent(id).owner, alice);
    }

    function test_setAllowanceUpAndDown() public {
        _deposit(alice, usdc, 1_000 * USDC);
        bytes32 id = _registerAgent(alice, agentWallet, uint128(100 * USDC), 0);

        vm.prank(alice);
        custos.setAllowance(id, uint128(1_000 * USDC));
        assertEq(custos.availableOf(alice), 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientAvailable.selector, 1_000 * USDC));
        custos.setAllowance(id, uint128(1_001 * USDC));

        vm.prank(alice);
        custos.setAllowance(id, uint128(50 * USDC));
        assertEq(custos.availableOf(alice), 950 * USDC);
    }

    /// @notice Mengubah periode tidak boleh mengembalikan kuota yang sudah terpakai —
    ///         kalau bisa, owner tinggal memanggilnya berulang untuk kuota tak terbatas.
    function test_setPeriodDoesNotResetUsage() public {
        _deposit(alice, usdc, 1_000 * USDC);
        bytes32 id = _registerAgent(alice, agentWallet, uint128(400 * USDC), 30 days);

        vm.prank(agentWallet);
        custos.executeSwap(address(market), true, uint128(200 * USDC), 0, 0);
        assertEq(custos.getAgent(id).usedInPeriod, 200 * USDC);

        vm.prank(alice);
        custos.setPeriod(id, 7 days);

        assertEq(custos.getAgent(id).usedInPeriod, 200 * USDC);
        assertEq(custos.remainingOf(id), 200 * USDC);
    }

    /// @notice Menurunkan allowance ke bawah pemakaian yang sudah tercatat adalah cara
    ///         owner menghentikan agent seketika. State `used > allowance` yang muncul
    ///         karenanya sah — yang wajib benar adalah headroom-nya nol, dan agent itu
    ///         tidak bisa lagi bergerak sampai periode berikutnya.
    function test_loweringAllowanceBelowUsageStopsAgent() public {
        _deposit(alice, usdc, 1_000 * USDC);
        bytes32 id = _registerAgent(alice, agentWallet, uint128(400 * USDC), 30 days);

        vm.prank(agentWallet);
        custos.executeSwap(address(market), true, uint128(300 * USDC), 0, 0);

        vm.prank(alice);
        custos.setAllowance(id, uint128(100 * USDC));

        assertEq(custos.getAgent(id).usedInPeriod, 300 * USDC);
        assertEq(custos.remainingOf(id), 0);
        assertEq(custos.delegatedOf(alice), 0);

        vm.prank(agentWallet);
        vm.expectRevert(abi.encodeWithSelector(AllowanceExceeded.selector, 0));
        custos.executeSwap(address(market), true, uint128(1 * USDC), 0, 0);

        // Periode berikutnya ia hidup lagi, dengan anggaran barunya.
        vm.warp(block.timestamp + 31 days);
        assertEq(custos.remainingOf(id), 100 * USDC);
    }

    function test_agentsPerOwnerIsCapped() public {
        _deposit(alice, usdc, 1_000 * USDC);
        for (uint256 i = 0; i < 32; i++) {
            _registerAgent(alice, address(uint160(0x1000 + i)), 0, 0);
        }
        vm.prank(alice);
        vm.expectRevert(TooManyAgents.selector);
        custos.registerAgent(bytes32("bot"), "d", address(uint160(0x2000)), 0, 0);
    }

    /// @notice Revoke membebaskan slot: batas 32 berlaku untuk agent hidup, bukan
    ///         seumur hidup akun.
    function test_revokeFreesAgentSlot() public {
        _deposit(alice, usdc, 1_000 * USDC);
        bytes32 first;
        for (uint256 i = 0; i < 32; i++) {
            bytes32 id = _registerAgent(alice, address(uint160(0x1000 + i)), 0, 0);
            if (i == 0) first = id;
        }
        vm.prank(alice);
        custos.revokeAgent(first);

        _registerAgent(alice, address(uint160(0x2000)), 0, 0);
        assertEq(custos.agentsOfOwner(alice).length, 32);
    }
}
