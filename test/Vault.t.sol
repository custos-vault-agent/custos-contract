// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {
    ExceedsAvailable, NotAuroraReceiver, NothingDeposited, ZeroAmount
} from "../src/Errors.sol";

contract VaultTest is Base {
    function test_depositCreditsMeasuredAmount() public {
        _deposit(alice, usdc, 1_000 * USDC);

        assertEq(custos.balanceOf(alice, address(usdc)), 1_000 * USDC);
        assertEq(custos.totalTracked(address(usdc)), 1_000 * USDC);
        assertEq(custos.availableOf(alice), 1_000 * USDC);
    }

    /// @notice Tidak ada parameter `amount` untuk dibohongi. Memanggil kredit dua kali
    ///         atas satu transfer hanya menghasilkan revert, bukan saldo ganda.
    function test_creditCannotBeClaimedTwice() public {
        _deposit(alice, usdc, 1_000 * USDC);

        vm.prank(receiver);
        vm.expectRevert(NothingDeposited.selector);
        custos.creditDeposit(bob, address(usdc));
    }

    function test_onlyAuroraReceiverCanCredit() public {
        usdc.mint(address(custos), 1_000 * USDC);

        vm.prank(alice);
        vm.expectRevert(NotAuroraReceiver.selector);
        custos.creditDeposit(alice, address(usdc));
    }

    function test_withdraw() public {
        _deposit(alice, usdc, 1_000 * USDC);

        vm.prank(alice);
        custos.withdraw(address(usdc), 400 * USDC);

        assertEq(usdc.balanceOf(alice), 400 * USDC);
        assertEq(custos.balanceOf(alice, address(usdc)), 600 * USDC);
        assertEq(custos.totalTracked(address(usdc)), 600 * USDC);
    }

    function test_withdrawRejectsZero() public {
        _deposit(alice, usdc, 1_000 * USDC);
        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        custos.withdraw(address(usdc), 0);
    }

    /// @notice Inilah janji produknya: dana yang sudah didelegasikan tidak bisa ditarik
    ///         diam-diam keluar dari jangkauan agent.
    function test_cannotWithdrawDelegated() public {
        _deposit(alice, usdc, 1_000 * USDC);
        _registerAgent(alice, agentWallet, uint128(600 * USDC), 0);

        assertEq(custos.availableOf(alice), 400 * USDC);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ExceedsAvailable.selector, 400 * USDC));
        custos.withdraw(address(usdc), 401 * USDC);

        vm.prank(alice);
        custos.withdraw(address(usdc), 400 * USDC);
        assertEq(custos.availableOf(alice), 0);
    }

    /// @notice Batas delegasi hanya mengikat aset akuntansi (D4). Aset base yang
    ///         diperoleh dari trading tetap bebas ditarik penuh.
    function test_nonAccountingAssetIsNotCapped() public {
        _deposit(alice, usdc, 1_000 * USDC);
        _deposit(alice, mon, 50 * MON);
        _registerAgent(alice, agentWallet, uint128(1_000 * USDC), 0);

        assertEq(custos.availableOf(alice), 0);

        vm.prank(alice);
        custos.withdraw(address(mon), 50 * MON);
        assertEq(mon.balanceOf(alice), 50 * MON);
    }

    function test_cannotWithdrawOthersFunds() public {
        _deposit(alice, usdc, 1_000 * USDC);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ExceedsAvailable.selector, 0));
        custos.withdraw(address(usdc), 1);
    }

    /// @notice Saldo dilacak per token; deposit token kedua tidak mengganggu yang pertama.
    function test_balancesAreTokenScoped() public {
        _deposit(alice, usdc, 1_000 * USDC);
        _deposit(alice, mon, 3 * MON);

        assertEq(custos.balanceOf(alice, address(usdc)), 1_000 * USDC);
        assertEq(custos.balanceOf(alice, address(mon)), 3 * MON);
    }
}
