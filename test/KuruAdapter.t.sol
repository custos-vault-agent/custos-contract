// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {KuruMarketAdapter} from "../src/adapters/KuruMarketAdapter.sol";
import {IKuruRouter} from "../src/interfaces/IKuruRouter.sol";
import {AllowanceExceeded, MarketQuoteMismatch} from "../src/Errors.sol";
import {MockKuruOrderBook} from "./mocks/MockKuruOrderBook.sol";
import {MockKuruRouter} from "./mocks/MockKuruRouter.sol";

/// @notice AgentVault → adapter → router Kuru, dengan bentuk panggilan yang sama
///         persis dengan mainnet. Adapter-nya sendiri tidak berubah dari v0.1 — yang
///         berubah adalah siapa yang memanggilnya (AgentVault, bukan CustosLogic).
contract KuruAdapterTest is Base {
    MockKuruRouter internal router;
    MockKuruOrderBook internal orderbook;
    KuruMarketAdapter internal adapter;

    bytes32 internal agentId;
    address internal vault;

    function setUp() public override {
        super.setUp();

        router = new MockKuruRouter();
        orderbook = new MockKuruOrderBook(address(mon), address(usdc));
        adapter = new KuruMarketAdapter(IKuruRouter(address(router)), address(orderbook));

        router.setPrice(address(orderbook), 2 * USDC, 1 * MON);
        mon.mint(address(router), 1_000_000 * MON);
        usdc.mint(address(router), 1_000_000 * USDC);

        (agentId, vault) = _registerAgent(alice, agentWallet, uint128(1_000 * USDC), 30 days);
        vm.prank(authority);
        custos.setMarketAllowed(agentId, address(adapter), true);
    }

    /// @notice Base dan quote diambil dari indeks 2 dan 4 tuple `getMarketParams`.
    ///         Tertukar berarti setiap notional dibebankan dalam mata uang yang salah.
    function test_adapterReadsBaseAndQuoteFromOrderbook() public view {
        assertEq(adapter.baseToken(), address(mon));
        assertEq(adapter.quoteToken(), address(usdc));
    }

    function test_allowlistRejectsAdapterWithWrongQuote() public {
        MockKuruOrderBook flipped = new MockKuruOrderBook(address(usdc), address(mon));
        KuruMarketAdapter wrong = new KuruMarketAdapter(IKuruRouter(address(router)), address(flipped));

        vm.prank(authority);
        vm.expectRevert(MarketQuoteMismatch.selector);
        custos.setMarketAllowed(agentId, address(wrong), true);
    }

    function test_agentBuysThroughKuru() public {
        vm.prank(agentWallet);
        uint128 charged = AgentVault(vault).executeSwap(address(adapter), true, uint128(500 * USDC), 0, 0);

        assertEq(charged, 500 * USDC);
        assertEq(mon.balanceOf(vault), 250 * MON);
    }

    /// @notice `minAmountOut` diteruskan apa adanya ke router; penjaga slippage yang
    ///         sebenarnya ada di sana, bukan di AgentVault.
    function test_minAmountOutReachesRouter() public {
        vm.prank(agentWallet);
        vm.expectRevert(MockKuruRouter.MockRouterSlippage.selector);
        AgentVault(vault).executeSwap(address(adapter), true, uint128(500 * USDC), uint128(251 * MON), 0);
    }

    /// @notice Router yang hanya memakai sebagian: sisanya wajib kembali ke vault dan
    ///         ke headroom agent, bukan mengendap di adapter.
    function test_partialFillReturnsRemainderThroughAdapter() public {
        router.setSpendBps(6_000);

        vm.prank(agentWallet);
        uint128 charged = AgentVault(vault).executeSwap(address(adapter), true, uint128(500 * USDC), 0, 0);

        assertEq(charged, 300 * USDC);
        assertEq(AgentVault(vault).usedInPeriod(), 300 * USDC);
        assertEq(mon.balanceOf(vault), 150 * MON);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(mon.balanceOf(address(adapter)), 0);
    }

    /// @notice Fill yang jauh lebih baik dari harga wajar tetap dibatasi allowance
    ///         efektif agent. Adapter tidak boleh menjadi jalan memutar untuk itu.
    function test_agentStillBoundedByAllowanceThroughAdapter() public {
        vm.prank(alice);
        custos.setAllowance(agentId, uint128(100 * USDC));

        vm.prank(agentWallet);
        vm.expectRevert(abi.encodeWithSelector(AllowanceExceeded.selector, 100 * USDC));
        AgentVault(vault).executeSwap(address(adapter), true, uint128(500 * USDC), 0, 0);
    }

    /// @notice Token yang nyasar ke adapter bukan milik penukar berikutnya.
    function test_strayTokensAreNotSweptToNextCaller() public {
        usdc.mint(address(adapter), 77 * USDC);
        router.setSpendBps(8_000);

        vm.prank(agentWallet);
        AgentVault(vault).executeSwap(address(adapter), true, uint128(500 * USDC), 0, 0);

        assertEq(usdc.balanceOf(address(adapter)), 77 * USDC);
    }

    /// @notice Buku besar (di sini: totalAssets vs saldo nyata) tetap tertutup setelah
    ///         lewat dua hop kontrak.
    function test_ledgerStaysBackedThroughAdapter() public {
        vm.prank(agentWallet);
        AgentVault(vault).executeSwap(address(adapter), true, uint128(400 * USDC), 0, 0);

        // H2: MON yang dibeli ikut dinilai (2 USD/MON lewat oracle), bukan hilang dari ledger.
        assertEq(AgentVault(vault).totalAssets(), usdc.balanceOf(vault) + (mon.balanceOf(vault) * 2 * USDC) / MON);
    }
}
