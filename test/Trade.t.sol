// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {Status} from "../src/Types.sol";
import {
    AgentNotActive,
    AllowanceExceeded,
    InsufficientAvailable,
    InsufficientBalance,
    MarketNotAllowed,
    MarketQuoteMismatch,
    SlippageExceeded
} from "../src/Errors.sol";
import {MockMarket} from "./mocks/MockMarket.sol";

contract TradeTest is Base {
    bytes32 internal agentId;

    function setUp() public override {
        super.setUp();
        _deposit(alice, usdc, 1_000 * USDC);
        agentId = _registerAgent(alice, agentWallet, uint128(400 * USDC), 30 days);
    }

    /* ---------------------------- jalur normal --------------------------- */

    function test_ownerCanSwapDirectlyWithoutAllowance() public {
        vm.prank(alice);
        uint128 charged = custos.executeSwap(address(market), true, uint128(600 * USDC), 0, 0);

        assertEq(charged, 600 * USDC);
        assertEq(custos.balanceOf(alice, address(usdc)), 400 * USDC);
        assertEq(custos.balanceOf(alice, address(mon)), 300 * MON);
        // Owner tidak punya allowance; agent-nya tidak tersentuh.
        assertEq(custos.getAgent(agentId).usedInPeriod, 0);
    }

    /// @notice Membelanjakan aset akuntansi yang sudah didelegasikan sama saja dengan
    ///         menariknya, jadi batasnya sama: `available`, bukan saldo penuh. Tanpa
    ///         aturan ini owner bisa mengubah dana yang tercadang untuk agent menjadi
    ///         aset base, dan allowance yang tersisa jadi janji tanpa isi.
    function test_ownerCannotSpendDelegatedFunds() public {
        assertEq(custos.availableOf(alice), 600 * USDC);

        // Angka dalam error adalah saldo aset akuntansi *setelah* trade — 1000 - 601 —
        // yang tidak lagi menutupi 400 yang didelegasikan.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientAvailable.selector, 399 * USDC));
        custos.executeSwap(address(market), true, uint128(601 * USDC), 0, 0);
    }

    /// @notice Sisi lain dari aturan yang sama: bagi agent, cek itu tidak pernah
    ///         menghalangi apa pun, karena saldo yang berkurang selalu diimbangi
    ///         allowance yang ikut berkurang sebesar notional yang sama.
    function test_agentCanSpendItsFullAllowance() public {
        vm.prank(agentWallet);
        custos.executeSwap(address(market), true, uint128(400 * USDC), 0, 0);

        assertEq(custos.balanceOf(alice, address(usdc)), 600 * USDC);
        assertEq(custos.delegatedOf(alice), 0);
        assertEq(custos.availableOf(alice), 600 * USDC);
    }

    function test_agentSwapConsumesAllowance() public {
        vm.prank(agentWallet);
        uint128 charged = custos.executeSwap(address(market), true, uint128(300 * USDC), 0, 0);

        assertEq(charged, 300 * USDC);
        assertEq(custos.getAgent(agentId).usedInPeriod, 300 * USDC);
        assertEq(custos.remainingOf(agentId), 100 * USDC);
        // Dana bergerak atas nama alice, bukan atas nama wallet agent.
        assertEq(custos.balanceOf(alice, address(mon)), 150 * MON);
        assertEq(custos.balanceOf(agentWallet, address(mon)), 0);
    }

    function test_consumeBlocksOverspend() public {
        vm.prank(agentWallet);
        vm.expectRevert(abi.encodeWithSelector(AllowanceExceeded.selector, 400 * USDC));
        custos.executeSwap(address(market), true, uint128(401 * USDC), 0, 0);
    }

    /// @notice Diperiksa dengan batas atas, dicatat dengan angka sebenarnya. Pasar yang
    ///         hanya memakai sebagian harus mengembalikan sisanya ke allowance, bukan
    ///         membakarnya.
    function test_partialFillRefundsAllowance() public {
        market.setSpendBps(6_000);

        vm.prank(agentWallet);
        uint128 charged = custos.executeSwap(address(market), true, uint128(400 * USDC), 0, 0);

        assertEq(charged, 240 * USDC);
        assertEq(custos.getAgent(agentId).usedInPeriod, 240 * USDC);
        assertEq(custos.remainingOf(agentId), 160 * USDC);
        // Sisa yang tidak jadi dipakai kembali ke saldo pemiliknya.
        assertEq(custos.balanceOf(alice, address(usdc)), 760 * USDC);
    }

    /* ------------------------------ identitas ---------------------------- */

    /// @notice Agent hanya bisa menggerakkan dana owner yang mendaftarkannya. Tidak ada
    ///         parameter yang bisa dipakai untuk menunjuk owner lain.
    function test_agentCannotTradeForAnotherOwner() public {
        _deposit(bob, usdc, 5_000 * USDC);

        vm.prank(agentWallet);
        custos.executeSwap(address(market), true, uint128(100 * USDC), 0, 0);

        assertEq(custos.balanceOf(bob, address(usdc)), 5_000 * USDC);
        assertEq(custos.balanceOf(alice, address(usdc)), 900 * USDC);
    }

    function test_pausedAgentCannotTrade() public {
        vm.prank(alice);
        custos.pauseAgent(agentId);

        vm.prank(agentWallet);
        vm.expectRevert(AgentNotActive.selector);
        custos.executeSwap(address(market), true, uint128(100 * USDC), 0, 0);
    }

    function test_revokedAgentCannotTrade() public {
        vm.prank(alice);
        custos.revokeAgent(agentId);

        vm.prank(agentWallet);
        vm.expectRevert(AgentNotActive.selector);
        custos.executeSwap(address(market), true, uint128(100 * USDC), 0, 0);
    }

    /// @notice Wallet asing tidak "menjadi agent"; ia hanya dirinya sendiri, dan
    ///         saldonya kosong.
    function test_strangerTradesOnlyItsOwnEmptyBalance() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(InsufficientBalance.selector, 0));
        custos.executeSwap(address(market), true, uint128(100 * USDC), 0, 0);
    }

    /// @notice Sapuan konfirmasi untuk aturan keras itu: tidak ada calldata yang bisa
    ///         membuat pemanggil sembarang menggerakkan dana alice. Kalau pernah ada
    ///         satu fungsi `external` yang menerima `address owner` tanpa mengikatnya
    ///         ke `msg.sender`, di sinilah ia ketahuan.
    function testFuzz_cannotActAsAnotherOwner(address caller, uint128 amountIn, bool isBuy)
        public
    {
        vm.assume(caller != alice && caller != agentWallet && caller != address(0));
        vm.assume(caller.code.length == 0);
        amountIn = uint128(bound(amountIn, 1, 1_000 * USDC));

        uint256 aliceUsdc = custos.balanceOf(alice, address(usdc));
        uint256 aliceMon = custos.balanceOf(alice, address(mon));

        vm.prank(caller);
        try custos.executeSwap(address(market), isBuy, amountIn, 0, type(uint128).max) {}
        catch {}

        assertEq(custos.balanceOf(alice, address(usdc)), aliceUsdc);
        assertEq(custos.balanceOf(alice, address(mon)), aliceMon);
    }

    /* -------------------------------- pasar ------------------------------ */

    function test_marketMustBeAllowed() public {
        MockMarket rogue = new MockMarket(address(mon), address(usdc), 2 * USDC, 1 * MON);

        vm.prank(alice);
        vm.expectRevert(MarketNotAllowed.selector);
        custos.executeSwap(address(rogue), true, uint128(100 * USDC), 0, 0);
    }

    function test_marketQuoteMustBeAccountingAsset() public {
        MockMarket wrong = new MockMarket(address(usdc), address(mon), 1, 1);

        vm.prank(authority);
        vm.expectRevert(MarketQuoteMismatch.selector);
        custos.setMarketAllowed(address(wrong), true);
    }

    /* -------------------------------- sisi jual -------------------------- */

    /// @notice Sisi jual ikut memakan allowance. Tanpa itu, agent yang dikompromikan
    ///         bisa menghabiskan seluruh aset base owner tanpa menyentuh anggarannya.
    function test_sellConsumesAllowance() public {
        _deposit(alice, mon, 100 * MON);

        vm.prank(agentWallet);
        uint128 charged =
            custos.executeSwap(address(market), false, uint128(100 * MON), 0, uint128(400 * USDC));

        assertEq(charged, 200 * USDC);
        assertEq(custos.getAgent(agentId).usedInPeriod, 200 * USDC);
        assertEq(custos.balanceOf(alice, address(mon)), 0);
        assertEq(custos.balanceOf(alice, address(usdc)), 1_200 * USDC);
    }

    function test_sellBlockedWhenAllowanceTooSmall() public {
        _deposit(alice, mon, 1_000 * MON);

        vm.prank(agentWallet);
        vm.expectRevert(abi.encodeWithSelector(AllowanceExceeded.selector, 400 * USDC));
        custos.executeSwap(address(market), false, uint128(1_000 * MON), 0, uint128(401 * USDC));
    }

    /// @notice Sebuah agent tidak bisa memakai `maxNotional` kecil untuk menyelundupkan
    ///         penjualan besar: fill yang melampaui deklarasinya ditolak.
    function test_sellRejectsFillAboveDeclaredCap() public {
        _deposit(alice, mon, 100 * MON);

        vm.prank(agentWallet);
        vm.expectRevert(SlippageExceeded.selector);
        custos.executeSwap(address(market), false, uint128(100 * MON), 0, uint128(10 * USDC));
    }

    /// @notice `maxNotional == 0` berarti tanpa batas — berguna bagi owner, tapi bagi
    ///         agent langsung tertolak karena melebihi allowance-nya.
    function test_unboundedSellRejectedForAgent() public {
        _deposit(alice, mon, 100 * MON);

        vm.prank(agentWallet);
        vm.expectRevert(abi.encodeWithSelector(AllowanceExceeded.selector, 400 * USDC));
        custos.executeSwap(address(market), false, uint128(100 * MON), 0, 0);

        vm.prank(alice);
        custos.executeSwap(address(market), false, uint128(100 * MON), 0, 0);
        assertEq(custos.balanceOf(alice, address(usdc)), 1_200 * USDC);
    }

    /* ------------------------------- periode ----------------------------- */

    function test_periodRollover() public {
        vm.prank(agentWallet);
        custos.executeSwap(address(market), true, uint128(400 * USDC), 0, 0);
        assertEq(custos.remainingOf(agentId), 0);

        // Sebelum batas periode, kuota masih habis.
        vm.warp(block.timestamp + 29 days);
        assertEq(custos.remainingOf(agentId), 0);

        // Setelah lewat, kuota pulih — terbaca langsung meski storage belum ditulis.
        vm.warp(block.timestamp + 2 days);
        assertEq(custos.remainingOf(agentId), 400 * USDC);

        // Dan trade berikutnya menuliskannya.
        _deposit(alice, usdc, 400 * USDC);
        vm.prank(agentWallet);
        custos.executeSwap(address(market), true, uint128(100 * USDC), 0, 0);
        assertEq(custos.getAgent(agentId).usedInPeriod, 100 * USDC);
    }

    /// @notice `periodLength == 0` berarti allowance sekali pakai yang tidak pernah
    ///         terisi ulang.
    function test_zeroPeriodNeverResets() public {
        bytes32 id = _registerAgent(alice, makeAddr("bot2"), uint128(100 * USDC), 0);

        vm.prank(makeAddr("bot2"));
        custos.executeSwap(address(market), true, uint128(100 * USDC), 0, 0);

        vm.warp(block.timestamp + 3650 days);
        assertEq(custos.remainingOf(id), 0);
    }

    /* ------------------------------ akuntansi ---------------------------- */

    /// @notice Janji intinya: trading tidak pernah mengurangi apa yang bisa ditarik
    ///         owner. Pembelian membuatnya tetap; penjualan menaikkannya.
    function test_tradingNeverReducesAvailable() public {
        uint256 before = custos.availableOf(alice);

        vm.prank(agentWallet);
        custos.executeSwap(address(market), true, uint128(300 * USDC), 0, 0);
        assertEq(custos.availableOf(alice), before, "buy harus netral");

        _deposit(alice, mon, 10 * MON);
        vm.prank(agentWallet);
        custos.executeSwap(address(market), false, uint128(10 * MON), 0, uint128(100 * USDC));
        assertGt(custos.availableOf(alice), before, "sell menambah dana nyata");
    }

    /// @notice Buku besar harus selalu tertutup saldo token yang benar-benar dipegang
    ///         kontrak (invarian I1).
    function test_ledgerStaysBackedAfterTrading() public {
        vm.prank(agentWallet);
        custos.executeSwap(address(market), true, uint128(300 * USDC), 0, 0);

        assertEq(custos.totalTracked(address(usdc)), custos.balanceOf(alice, address(usdc)));
        assertEq(custos.totalTracked(address(mon)), custos.balanceOf(alice, address(mon)));
        assertLe(custos.totalTracked(address(usdc)), usdc.balanceOf(address(custos)));
        assertLe(custos.totalTracked(address(mon)), mon.balanceOf(address(custos)));
    }
}
