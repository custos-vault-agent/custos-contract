// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {CustosLogic} from "../src/CustosLogic.sol";
import {CustosProxy} from "../src/CustosProxy.sol";
import {KuruMarketAdapter} from "../src/adapters/KuruMarketAdapter.sol";
import {IKuruRouter} from "../src/interfaces/IKuruRouter.sol";
import {AllowanceExceeded, MarketQuoteMismatch} from "../src/Errors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockKuruOrderBook} from "./mocks/MockKuruOrderBook.sol";
import {MockKuruRouter} from "./mocks/MockKuruRouter.sol";

/// @notice Custos → adapter → router Kuru, dengan bentuk panggilan yang sama persis
///         dengan mainnet. Ini yang membuat langkah 7 (§10) bisa selesai dan teruji
///         sebelum ada RPC Monad yang tersentuh.
contract KuruAdapterTest is Test {
    CustosLogic internal custos;
    MockERC20 internal usdc;
    MockERC20 internal mon;
    MockKuruRouter internal router;
    MockKuruOrderBook internal orderbook;
    KuruMarketAdapter internal adapter;

    address internal authority = makeAddr("authority");
    address internal receiver = makeAddr("auroraReceiver");
    address internal alice = makeAddr("alice");
    address internal agentWallet = makeAddr("agentWallet");

    uint256 internal constant USDC = 1e6;
    uint256 internal constant MON = 1e18;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        mon = new MockERC20("Monad", "MON", 18);

        custos = CustosLogic(
            address(
                new CustosProxy(
                    address(new CustosLogic()),
                    abi.encodeCall(CustosLogic.initialize, (authority, address(usdc)))
                )
            )
        );

        router = new MockKuruRouter();
        orderbook = new MockKuruOrderBook(address(mon), address(usdc));
        adapter = new KuruMarketAdapter(IKuruRouter(address(router)), address(orderbook));

        // 1 MON = 2 USDC.
        router.setPrice(address(orderbook), 2 * USDC, 1 * MON);
        mon.mint(address(router), 1_000_000 * MON);
        usdc.mint(address(router), 1_000_000 * USDC);

        vm.startPrank(authority);
        custos.setAuroraReceiver(receiver);
        custos.setMarketAllowed(address(adapter), true);
        vm.stopPrank();

        _deposit(alice, usdc, 1_000 * USDC);
    }

    function _deposit(address owner, MockERC20 token, uint256 amount) internal {
        token.mint(address(custos), amount);
        vm.prank(receiver);
        custos.creditDeposit(owner, address(token));
    }

    /* ---------------------------- pembacaan pasar ------------------------- */

    /// @notice Base dan quote diambil dari indeks 2 dan 4 tuple `getMarketParams`.
    ///         Tertukar berarti setiap notional dibebankan dalam mata uang yang salah,
    ///         dan tidak ada satu pun test lain yang akan menangkapnya.
    function test_adapterReadsBaseAndQuoteFromOrderbook() public view {
        assertEq(adapter.baseToken(), address(mon));
        assertEq(adapter.quoteToken(), address(usdc));
    }

    /// @notice Allowlist tetap menolak pasar yang quote-nya bukan aset akuntansi, bahkan
    ///         ketika ia datang lewat adapter Kuru yang sah.
    function test_allowlistRejectsAdapterWithWrongQuote() public {
        MockKuruOrderBook flipped = new MockKuruOrderBook(address(usdc), address(mon));
        KuruMarketAdapter wrong =
            new KuruMarketAdapter(IKuruRouter(address(router)), address(flipped));

        vm.prank(authority);
        vm.expectRevert(MarketQuoteMismatch.selector);
        custos.setMarketAllowed(address(wrong), true);
    }

    /* ------------------------------ jalur normal -------------------------- */

    function test_ownerBuysThroughKuru() public {
        vm.prank(alice);
        uint128 charged = custos.executeSwap(address(adapter), true, uint128(500 * USDC), 0, 0);

        assertEq(charged, 500 * USDC);
        assertEq(custos.balanceOf(alice, address(usdc)), 500 * USDC);
        assertEq(custos.balanceOf(alice, address(mon)), 250 * MON);
    }

    function test_agentSellsThroughKuru() public {
        _deposit(alice, mon, 100 * MON);
        vm.prank(alice);
        bytes32 id = custos.registerAgent(
            bytes32("kuru-bot"), "kuru bot", agentWallet, uint128(400 * USDC), 30 days
        );

        vm.prank(agentWallet);
        uint128 charged =
            custos.executeSwap(address(adapter), false, uint128(100 * MON), 0, uint128(400 * USDC));

        assertEq(charged, 200 * USDC);
        assertEq(custos.getAgent(id).usedInPeriod, 200 * USDC);
        assertEq(custos.balanceOf(alice, address(mon)), 0);
        assertEq(custos.balanceOf(alice, address(usdc)), 1_200 * USDC);
    }

    /// @notice `minAmountOut` diteruskan apa adanya ke router; penjaga slippage yang
    ///         sebenarnya ada di sana, bukan di Custos.
    function test_minAmountOutReachesRouter() public {
        vm.prank(alice);
        vm.expectRevert(MockKuruRouter.MockRouterSlippage.selector);
        custos.executeSwap(address(adapter), true, uint128(500 * USDC), uint128(251 * MON), 0);
    }

    /* --------------------------- perilaku buruk --------------------------- */

    /// @notice Router yang hanya memakai sebagian: sisanya wajib kembali ke saldo owner
    ///         dan ke headroom agent, bukan mengendap di adapter.
    function test_partialFillReturnsRemainderThroughAdapter() public {
        router.setSpendBps(6_000);
        vm.prank(alice);
        bytes32 id = custos.registerAgent(
            bytes32("kuru-bot"), "kuru bot", agentWallet, uint128(500 * USDC), 30 days
        );

        vm.prank(agentWallet);
        uint128 charged = custos.executeSwap(address(adapter), true, uint128(500 * USDC), 0, 0);

        assertEq(charged, 300 * USDC);
        assertEq(custos.remainingOf(id), 200 * USDC);
        assertEq(custos.balanceOf(alice, address(usdc)), 700 * USDC);
        assertEq(custos.balanceOf(alice, address(mon)), 150 * MON);

        // Adapter tidak menyimpan apa pun di antara transaksi.
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(mon.balanceOf(address(adapter)), 0);
    }

    /// @notice Fill yang jauh lebih baik dari harga wajar tetap dibatasi allowance agent.
    ///         Adapter tidak boleh menjadi jalan memutar untuk itu.
    function test_agentStillBoundedByAllowanceThroughAdapter() public {
        vm.prank(alice);
        custos.registerAgent(
            bytes32("kuru-bot"), "kuru bot", agentWallet, uint128(100 * USDC), 30 days
        );

        vm.prank(agentWallet);
        vm.expectRevert(abi.encodeWithSelector(AllowanceExceeded.selector, 100 * USDC));
        custos.executeSwap(address(adapter), true, uint128(500 * USDC), 0, 0);
    }

    /// @notice Token yang nyasar ke adapter bukan milik penukar berikutnya. Sisa dihitung
    ///         sebagai selisih, bukan saldo penuh.
    function test_strayTokensAreNotSweptToNextCaller() public {
        usdc.mint(address(adapter), 77 * USDC);
        router.setSpendBps(8_000);

        vm.prank(alice);
        custos.executeSwap(address(adapter), true, uint128(500 * USDC), 0, 0);

        // 100 USDC tak terpakai kembali ke alice; 77 USDC nyasar tetap di adapter.
        assertEq(custos.balanceOf(alice, address(usdc)), 600 * USDC);
        assertEq(usdc.balanceOf(address(adapter)), 77 * USDC);
    }

    /// @notice Buku besar tetap tertutup saldo nyata setelah lewat dua hop kontrak.
    function test_ledgerStaysBackedThroughAdapter() public {
        vm.prank(alice);
        custos.executeSwap(address(adapter), true, uint128(400 * USDC), 0, 0);

        assertEq(custos.totalTracked(address(usdc)), custos.balanceOf(alice, address(usdc)));
        assertEq(custos.totalTracked(address(mon)), custos.balanceOf(alice, address(mon)));
        assertLe(custos.totalTracked(address(usdc)), usdc.balanceOf(address(custos)));
        assertLe(custos.totalTracked(address(mon)), mon.balanceOf(address(custos)));
    }
}
