// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IKuruOrderBook} from "../interfaces/IKuruOrderBook.sol";
import {IKuruRouter} from "../interfaces/IKuruRouter.sol";
import {IMarket} from "../interfaces/IMarket.sol";
import {ZeroAddress} from "../Errors.sol";

/// @notice Menerjemahkan satu pasar Kuru menjadi bentuk `IMarket` yang dipahami Custos.
///
/// @dev Satu adapter membungkus **satu** orderbook. Itu disengaja: seluruh model allowance
///      bertumpu pada `quoteToken() == accountingAsset`, dan properti itu hanya bermakna
///      untuk satu pasar tertentu. Sebuah adapter yang merutekan ke pasar mana pun akan
///      membuat pemeriksaan di `setMarketAllowed` kehilangan arti — ia lulus sekali saat
///      di-allowlist lalu tidak mengikat apa pun sesudahnya.
///
///      **Adapter tidak memegang kepercayaan apa pun.** Ia tidak punya owner, tidak punya
///      state, dan tidak menyimpan dana di antara transaksi. Siapa pun boleh memanggilnya;
///      ia hanya bisa memindahkan token yang ditarik dari `msg.sender` pada panggilan itu
///      juga, dan mengembalikan seluruh hasilnya ke `msg.sender`. Custos pun tidak
///      mempercayai nilai baliknya: `TradeModule._callMarket` mengukur perpindahan dari
///      selisih saldonya sendiri.
contract KuruMarketAdapter is IMarket {
    using SafeERC20 for IERC20;

    IKuruRouter public immutable router;
    address public immutable orderbook;

    address internal immutable _base;
    address internal immutable _quote;

    constructor(IKuruRouter router_, address orderbook_) {
        if (address(router_) == address(0) || orderbook_ == address(0)) revert ZeroAddress();
        router = router_;
        orderbook = orderbook_;

        // Dibaca sekali dan dibekukan. Kalau dibaca ulang tiap swap, sebuah pasar yang
        // di-upgrade bisa menukar arti base dan quote di bawah kaki allowlist yang sudah
        // terlanjur menyetujuinya.
        (,, address baseAsset,, address quoteAsset,,,,,,) =
            IKuruOrderBook(orderbook_).getMarketParams();
        if (baseAsset == address(0) || quoteAsset == address(0)) revert ZeroAddress();
        _base = baseAsset;
        _quote = quoteAsset;
    }

    function baseToken() external view returns (address) {
        return _base;
    }

    function quoteToken() external view returns (address) {
        return _quote;
    }

    /// @inheritdoc IMarket
    function swap(bool isBuy, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut)
    {
        (address tokenIn, address tokenOut) = isBuy ? (_quote, _base) : (_base, _quote);

        // Saldo dicatat *sebelum* penarikan, jadi selisihnya adalah sisa dari swap ini
        // saja. Membaca saldo penuh di akhir akan menyapu token yang kebetulan nyasar ke
        // adapter ini ke pemanggil berikutnya.
        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        _route(isBuy, tokenIn, tokenOut, amountIn, minAmountOut);

        // Izin sisa dibersihkan tanpa syarat: router yang hanya memakai sebagian tidak
        // boleh meninggalkan klaim yang masih hidup atas adapter ini.
        IERC20(tokenIn).forceApprove(address(router), 0);

        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        uint256 unspent = IERC20(tokenIn).balanceOf(address(this)) - inBefore;

        // Adapter tidak menyimpan apa pun di antara transaksi. Semua yang masuk keluar
        // lagi ke pemanggil yang sama, di transaksi yang sama.
        if (unspent != 0) IERC20(tokenIn).safeTransfer(msg.sender, unspent);
        if (amountOut != 0) IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }

    /// @dev Membangun rute satu hop dan memanggil router. Dipisahkan dari `swap` bukan
    ///      demi kerapian melainkan karena keduanya bersama-sama melampaui batas 16 slot
    ///      stack solc — kendala yang sama yang memecah `TradeModule.executeSwap`.
    function _route(
        bool isBuy,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal {
        address[] memory route = new address[](1);
        route[0] = orderbook;
        bool[] memory sides = new bool[](1);
        sides[0] = isBuy;
        // Custos hanya mengurus ERC-20; jalur native tidak pernah dipakai dan
        // `msg.value` selalu nol.
        bool[] memory nativeSend = new bool[](1);

        router.anyToAnySwap(route, sides, nativeSend, tokenIn, tokenOut, amountIn, minAmountOut);
    }
}
