// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AgentCore} from "./AgentCore.sol";
import {AccessStorage} from "../storage/AccessStorage.sol";
import {Agent} from "../Types.sol";
import {AgentStorage} from "../storage/AgentStorage.sol";
import {IMarket} from "../interfaces/IMarket.sol";
import {TradingLayout, TradingStorage} from "../storage/TradingStorage.sol";
import {VaultLayout, VaultStorage} from "../storage/VaultStorage.sol";
import {
    AllowanceExceeded,
    InsufficientBalance,
    MarketNotAllowed,
    MarketQuoteMismatch,
    SlippageExceeded,
    ZeroAmount
} from "../Errors.sol";
import {AgentPeriodRolled, MarketAllowedChanged, SwapExecuted} from "../Events.sol";

/// @notice Eksekusi market order dengan konsumsi allowance yang atomik.
abstract contract TradeModule is AgentCore {
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    /// @notice Mengizinkan atau melarang sebuah pasar.
    /// @dev Kecocokan quote token diperiksa di sini, sekali, bukan di setiap swap.
    ///      Seluruh model allowance bertumpu pada asumsi bahwa sisi quote adalah aset
    ///      akuntansi (D4); pasar dengan quote lain akan membuat setiap angka notional
    ///      membandingkan dua mata uang berbeda.
    function setMarketAllowed(address market, bool allowed) external onlyUpgradeAuthority {
        if (allowed && IMarket(market).quoteToken() != AccessStorage.layout().accountingAsset) {
            revert MarketQuoteMismatch();
        }
        TradingStorage.layout().allowedMarkets[market] = allowed;
        emit MarketAllowedChanged(market, allowed);
    }

    /// @notice Menukar aset lewat pasar yang diizinkan, atas nama pemilik dana.
    ///
    /// @param isBuy True untuk membelanjakan aset akuntansi demi base; false sebaliknya.
    /// @param amountIn Buy: jumlah quote yang dibelanjakan. Sell: jumlah base yang dijual.
    /// @param minAmountOut Batas slippage yang diteruskan ke pasar.
    /// @param maxNotional Nilai aset akuntansi terbesar yang boleh berpindah dalam trade
    ///        ini. Diabaikan pada buy — di sana `amountIn` sudah menjadi batasnya.
    /// @return notionalCharged Notional sebenarnya yang dibebankan ke allowance agent.
    ///
    /// @dev Spec awal memakai `size × worstPrice` untuk menghitung batas notional. Itu
    ///      dibuang: perkalian tersebut menuntut skala harga dan desimal base yang tidak
    ///      pernah didefinisikan, dan salah satu dari keduanya cukup untuk menggeser
    ///      seluruh perhitungan allowance beberapa kali lipat. Menyatakan batas langsung
    ///      dalam unit aset akuntansi menghapus kelas bug itu seluruhnya.
    ///
    ///      Sisi jual ikut memakan allowance. Kalau tidak, sebuah agent yang dikompromikan
    ///      bisa menghabiskan seluruh aset base milik owner dengan harga berapa pun tanpa
    ///      menyentuh anggarannya — allowance hanya akan menjaga satu arah saja.
    ///
    ///      Owner yang bertindak langsung tetap dibatasi `available`, bukan saldo penuh:
    ///      membelanjakan aset akuntansi yang sudah didelegasikan sama saja dengan
    ///      menariknya.
    function executeSwap(
        address market,
        bool isBuy,
        uint128 amountIn,
        uint128 minAmountOut,
        uint128 maxNotional
    ) external nonReentrant whenNotPaused returns (uint128 notionalCharged) {
        if (amountIn == 0) revert ZeroAmount();
        if (!TradingStorage.layout().allowedMarkets[market]) revert MarketNotAllowed();

        (address owner, bytes32 agentId) = _resolveActor();

        // Batas atas notional yang diperiksa sebelum eksekusi. Pada buy, yang keluar dari
        // vault persis `amountIn`; pada sell, yang masuk dibatasi oleh deklarasi pemanggil.
        // Pada sell tanpa batas yang dinyatakan, batasnya menjadi tak berhingga. Itu
        // hanya berguna bagi owner yang bertindak langsung: bagi agent, batas tak
        // berhingga langsung ditolak `_consumeAllowance` karena melebihi allowance.
        uint128 notionalMax = isBuy
            ? amountIn
            : (maxNotional == 0 ? type(uint128).max : maxNotional);
        _consumeAllowance(agentId, notionalMax);

        (uint128 baseAmount, uint128 quoteAmount) =
            _swapAndSettle(owner, market, isBuy, amountIn, minAmountOut);

        notionalCharged = quoteAmount;
        // Pada sell, fill yang lebih baik dari yang dideklarasikan tetap ditolak: menerima
        // begitu saja berarti membiarkan agent memindahkan nilai melebihi anggarannya.
        // Agent yang jujur cukup menyetel `maxNotional` sebesar sisa anggarannya.
        if (notionalCharged > notionalMax) revert SlippageExceeded();

        // Diperiksa dengan batas atas, dicatat dengan angka sebenarnya. Membalik urutan
        // ini membuat agent bisa melewati allowance persis sebesar slippage-nya.
        _refundAllowance(agentId, notionalMax - notionalCharged);

        // Aset akuntansi yang sudah didelegasikan tidak boleh dibelanjakan, persis seperti
        // ia tidak boleh ditarik (§4.2). Untuk agent ini selalu terpenuhi dengan
        // sendirinya — saldo yang berkurang diimbangi allowance yang ikut berkurang
        // sebesar notional yang sama. Yang benar-benar dijaga di sini adalah owner yang
        // bertindak langsung: tanpa cek ini ia bisa membelanjakan dana yang masih
        // tercadang untuk agent-nya, dan invarian I3 jebol tanpa satu baris kode pun
        // yang keliru. Diletakkan setelah refund, bukan sebelum, supaya yang dinilai
        // adalah delegasi yang sudah final.
        _requireSolvent(owner);

        emit SwapExecuted(owner, agentId, market, isBuy, baseAmount, quoteAmount, notionalCharged);
    }

    /* ------------------------------ internal ----------------------------- */

    /// @dev Memindahkan dana, memanggil pasar, lalu mencatat hasilnya. Dipisahkan dari
    ///      `executeSwap` bukan demi kerapian melainkan karena keduanya bersama-sama
    ///      melampaui batas 16 slot stack solc.
    /// @return baseAmount Base yang berpindah, arah mana pun.
    /// @return quoteAmount Aset akuntansi yang berpindah, arah mana pun.
    function _swapAndSettle(
        address owner,
        address market,
        bool isBuy,
        uint128 amountIn,
        uint128 minAmountOut
    ) internal returns (uint128 baseAmount, uint128 quoteAmount) {
        (address tokenIn, address tokenOut) = isBuy
            ? (AccessStorage.layout().accountingAsset, IMarket(market).baseToken())
            : (IMarket(market).baseToken(), AccessStorage.layout().accountingAsset);

        VaultLayout storage v = VaultStorage.layout();
        uint256 bal = v.balance[owner][tokenIn];
        if (bal < amountIn) revert InsufficientBalance(bal);

        // Effects sebelum interactions. `nonReentrant` ada, tapi urutan inilah yang
        // membuat reentrancy tidak punya apa pun untuk dieksploitasi.
        v.balance[owner][tokenIn] = bal - amountIn;

        (uint256 spent, uint256 received) =
            _callMarket(market, tokenIn, tokenOut, isBuy, amountIn, minAmountOut);

        // Yang tidak jadi dipakai pasar dikembalikan ke pemiliknya.
        if (spent < amountIn) v.balance[owner][tokenIn] += amountIn - spent;
        v.balance[owner][tokenOut] += received;
        v.totalTracked[tokenIn] -= spent;
        v.totalTracked[tokenOut] += received;

        // Cast terperiksa, bukan kenyamanan: sebuah pasar yang mengembalikan lebih dari
        // 2^128 akan terpotong menjadi angka kecil, dan notional kecil itulah yang
        // dibebankan ke allowance — jalan pintas melewati batas agent sepenuhnya.
        return isBuy
            ? (received.toUint128(), spent.toUint128())
            : (spent.toUint128(), received.toUint128());
    }

    /// @dev Memanggil pasar dan mengukur perpindahan sebenarnya.
    /// @return spent Token yang benar-benar keluar dari kontrak.
    /// @return received Token yang benar-benar masuk.
    function _callMarket(
        address market,
        address tokenIn,
        address tokenOut,
        bool isBuy,
        uint128 amountIn,
        uint128 minAmountOut
    ) internal returns (uint256 spent, uint256 received) {
        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        IERC20(tokenIn).forceApprove(market, amountIn);
        IMarket(market).swap(isBuy, amountIn, minAmountOut);
        // Sisa izin dibersihkan: pasar yang hanya memakai sebagian tidak boleh
        // meninggalkan klaim atas dana pengguna lain.
        IERC20(tokenIn).forceApprove(market, 0);

        // Perpindahan diukur, bukan dipercaya dari nilai balik pasar. Ini yang menjaga
        // buku besar tetap cocok dengan saldo sebenarnya meski pasar berperilaku aneh
        // atau token memotong fee saat transfer (invarian I1).
        spent = inBefore - IERC20(tokenIn).balanceOf(address(this));
        received = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
    }

    /// @dev Owner yang bertindak langsung (`agentId == 0`) tidak punya allowance:
    ///      batasannya adalah saldonya sendiri.
    function _consumeAllowance(bytes32 agentId, uint128 notional) internal {
        if (agentId == bytes32(0)) return;

        Agent storage a = AgentStorage.layout().agents[agentId];
        (bool rolled, uint128 usedBefore) = _rollPeriod(a);
        if (rolled) emit AgentPeriodRolled(agentId, a.periodStart, usedBefore);

        uint256 spentAfter = uint256(a.usedInPeriod) + a.reserved + notional;
        if (spentAfter > a.allowance) {
            uint256 committed = uint256(a.usedInPeriod) + a.reserved;
            revert AllowanceExceeded(committed >= a.allowance ? 0 : a.allowance - committed);
        }
        a.usedInPeriod += notional;
    }

    function _refundAllowance(bytes32 agentId, uint128 amount) internal {
        if (agentId == bytes32(0) || amount == 0) return;
        AgentStorage.layout().agents[agentId].usedInPeriod -= amount;
    }

    /* ------------------------------- views ------------------------------- */

    function isMarketAllowed(address market) external view returns (bool) {
        return TradingStorage.layout().allowedMarkets[market];
    }
}
