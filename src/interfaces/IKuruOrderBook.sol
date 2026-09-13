// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Potongan antarmuka orderbook Kuru yang benar-benar dipakai Custos.
///
/// @dev Hanya `getMarketParams` yang dibutuhkan: dari sanalah adapter tahu token base dan
///      quote sebuah pasar, dan `TradeModule.setMarketAllowed` menolak pasar yang quote-nya
///      bukan aset akuntansi (D4). Sisa antarmuka orderbook sengaja tidak disalin — apa
///      yang tidak dipanggil tidak perlu dijaga tetap sinkron.
interface IKuruOrderBook {
    /// @notice Parameter pasar, urutannya persis seperti yang dikembalikan kontrak Kuru.
    ///
    /// @dev Urutan tuple ini diverifikasi terhadap `ParamFetcher.getMarketParams` di
    ///      kuru-sdk, bukan ditebak: indeks 2 adalah base dan indeks 4 adalah quote.
    ///      Membaliknya akan lolos kompilasi, lolos allowlist kalau kebetulan simetris,
    ///      lalu membebankan notional dalam mata uang yang salah.
    function getMarketParams()
        external
        view
        returns (
            uint32 pricePrecision,
            uint96 sizePrecision,
            address baseAssetAddress,
            uint256 baseAssetDecimals,
            address quoteAssetAddress,
            uint256 quoteAssetDecimals,
            uint32 tickSize,
            uint96 minSize,
            uint96 maxSize,
            uint256 takerFeeBps,
            uint256 makerFeeBps
        );
}
