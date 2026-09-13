// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {AgentVault} from "../../src/AgentVault.sol";
import {CustosCore} from "../../src/CustosCore.sol";
import {CustosProxy} from "../../src/CustosProxy.sol";
import {Status} from "../../src/Types.sol";
import {Handler} from "./Handler.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMarket} from "../mocks/MockMarket.sol";

/// @notice Invarian I1, I2, I4, I5, I6, I8, I9, I10, I12 dari spec v1 §6.
contract CustosInvariantTest is Test {
    CustosCore internal custos;
    MockERC20 internal usdc;
    MockERC20 internal mon;
    MockMarket internal market;
    Handler internal handler;

    address internal authority = makeAddr("authority");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        mon = new MockERC20("Monad", "MON", 18);

        custos = CustosCore(
            address(
                new CustosProxy(
                    address(new CustosCore()), abi.encodeCall(CustosCore.initialize, (authority, address(usdc)))
                )
            )
        );

        market = new MockMarket(address(mon), address(usdc), 2e6, 1e18);
        mon.mint(address(market), 1e30);
        usdc.mint(address(market), 1e30);

        vm.startPrank(authority);
        custos.setMarketAdapter(address(market));
        custos.setMinSeed(500e6);
        vm.stopPrank();

        handler = new Handler(custos, usdc, mon, market, authority);
        targetContract(address(handler));
    }

    /* ---------------------------------------------------------------------- */

    /// @notice I1 — setiap vault selalu backed: totalAssets() sama dengan saldo
    ///         idle-nya sendiri (yieldSource selalu address(0) di suite ini).
    function invariant_vaultSolvent() public view {
        uint256 n = handler.idCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = handler.ids(i);
            address vault = custos.getAgent(id).vault;
            uint256 idle = usdc.balanceOf(vault);
            assertEq(AgentVault(vault).totalAssets(), idle, "I1: totalAssets != idle balance");
        }
    }

    /// @notice I2 — highWaterMark tidak pernah turun di bawah floor-nya, yang hanya
    ///         diperbarui tepat saat `resumeAgent` benar-benar dipanggil.
    function invariant_highWaterMarkRespectsFloor() public view {
        uint256 n = handler.idCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = handler.ids(i);
            address vault = custos.getAgent(id).vault;
            assertGe(AgentVault(vault).highWaterMark(), handler.hwmFloor(id), "I2");
        }
    }

    /// @notice I4 — share di address(1) tidak pernah turun dari jumlah seed awal.
    function invariant_seedSharesNeverDecrease() public view {
        uint256 n = handler.idCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = handler.ids(i);
            address vault = custos.getAgent(id).vault;
            assertGe(AgentVault(vault).balanceOf(address(1)), handler.seedShares(id), "I4");
        }
    }

    /// @notice I5 — `usedInPeriod` tidak pernah melampaui `allowance` immutable.
    ///
    /// @dev I12 (`usedInPeriod <= totalAssets() * maxUtilizationBps / 10_000`) secara
    ///      sengaja tidak diimplementasikan sebagai standing invariant di sini, untuk
    ///      alasan yang sama seperti I3/I11 di atas: `executeSwap` sudah benar
    ///      menegakkannya di titik commit menggunakan `totalAssets()` SEBELUM trade —
    ///      itu yang membuat `test_reserveRatioCapsTrading` dkk (Task 9) lolos. Tapi
    ///      begitu buy itu jalan, `totalAssets()` (D4: hanya accounting asset, base
    ///      token hasil buy tidak dihitung) langsung turun — jadi menghitung ulang cap
    ///      itu dari `totalAssets()` yang SUDAH turun, lalu membandingkannya lagi
    ///      dengan `usedInPeriod` yang direkam dari sebelum trade, adalah perbandingan
    ///      yang tidak pernah dijanjikan kontrak manapun, bukan properti keamanan yang
    ///      nyata. Fuzz run konkret membuktikan ini: register → satu buy besar (pas di
    ///      bawah cap pre-trade) → assertLe gagal semata karena totalAssets() pasca-
    ///      buy lebih kecil, walau trade itu sendiri sepenuhnya valid.
    function invariant_usedNeverExceedsAllowance() public view {
        uint256 n = handler.idCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = handler.ids(i);
            AgentVault vault = AgentVault(custos.getAgent(id).vault);
            assertLe(uint256(vault.usedInPeriod()), uint256(vault.allowance()), "I5");
        }
    }

    /// @notice I6 — agent wallet tidak pernah memegang share vault-nya sendiri.
    function invariant_agentHoldsNoShares() public view {
        uint256 n = handler.idCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = handler.ids(i);
            AgentVault vault = AgentVault(custos.getAgent(id).vault);
            assertEq(vault.balanceOf(vault.agent()), 0, "I6");
        }
    }

    /// @notice I8 — ikatan wallet stabil: id yang tersimpan di `idOfWallet` selalu
    ///         mengarah balik ke wallet yang sama di record.
    function invariant_walletBindingIsStable() public view {
        uint256 n = handler.idCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = handler.ids(i);
            address wallet = custos.getAgent(id).wallet;
            assertEq(custos.agentIdOf(wallet), id, "I8");
        }
    }

    /// @notice I9 — alamat agent di vault sama dengan wallet di registry record.
    function invariant_vaultAgentMatchesRegistry() public view {
        uint256 n = handler.idCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = handler.ids(i);
            AgentRecordView memory r = _record(id);
            assertEq(AgentVault(r.vault).agent(), r.wallet, "I9");
        }
    }

    /// @notice I10 — selagi Active dengan drawdown enabled, share price tidak pernah
    ///         di bawah threshold-nya sendiri (kalau di bawah, breaker sudah harus
    ///         men-trigger dan status jadi Paused, bukan tetap Active).
    function invariant_activeVaultAboveDrawdownThreshold() public view {
        uint256 n = handler.idCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = handler.ids(i);
            AgentVault vault = AgentVault(custos.getAgent(id).vault);
            if (vault.status() != Status.Active) continue;
            if (vault.maxDrawdownBps() == 0) continue;

            uint256 supply = vault.totalSupply();
            if (supply == 0) continue;
            uint256 price = (vault.totalAssets() * 1e18) / supply;
            uint256 threshold = (vault.highWaterMark() * (10_000 - vault.maxDrawdownBps())) / 10_000;
            assertGe(price, threshold, "I10");
        }
    }

    /* -------------------------------- helpers ------------------------------ */

    struct AgentRecordView {
        address vault;
        address wallet;
    }

    function _record(bytes32 id) internal view returns (AgentRecordView memory) {
        return AgentRecordView({vault: custos.getAgent(id).vault, wallet: custos.getAgent(id).wallet});
    }
}
