// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Router Kuru — satu-satunya fungsi yang dipanggil Custos.
///
/// @dev Tanda tangan disalin dari ABI resmi kuru-sdk (`abi/Router.json`), bukan dari
///      dokumentasi: implementasi router di mainnet tidak terverifikasi di explorer, jadi
///      ABI SDK adalah sumber kebenaran yang tersedia. Router mainnet Monad berada di
///      `0xd651346d7c789536ebf06dc72aE3C8502cd695CC` (proxy ERC-1967).
///
///      **Kenapa lewat router, bukan langsung ke orderbook.** `placeAndExecuteMarketBuy`
///      dan `placeAndExecuteMarketSell` di orderbook menerima ukuran dalam *unit presisi*
///      (`uint96`, diskalakan `sizePrecision`/`pricePrecision`), sementara `anyToAnySwap`
///      menerima jumlah dalam **desimal token apa adanya**. Konversi presisi itu persis
///      kelas kesalahan yang sudah dibuang sekali dari spec ini saat `size × worstPrice`
///      diganti (§4.4); tidak ada alasan memasukkannya kembali lewat pintu belakang.
interface IKuruRouter {
    /// @notice Menukar `_amount` `_debitToken` menjadi `_creditToken` lewat satu atau
    ///         beberapa orderbook.
    ///
    /// @param _marketAddresses Rute: alamat orderbook per hop.
    /// @param _isBuy Arah tiap hop, sejajar dengan `_marketAddresses`.
    /// @param _nativeSend Apakah hop mengirim MON native. Custos selalu `false` — dana
    ///        yang dikelola Custos adalah ERC-20, dan `msg.value` tidak pernah dipakai.
    /// @param _debitToken Token yang dibelanjakan; router menariknya dari `msg.sender`.
    /// @param _creditToken Token yang diterima; router mengirimnya ke `msg.sender`.
    /// @param _amount Jumlah `_debitToken`, dalam desimal token.
    /// @param _minAmountOut Batas slippage; router revert bila tidak tercapai.
    function anyToAnySwap(
        address[] calldata _marketAddresses,
        bool[] calldata _isBuy,
        bool[] calldata _nativeSend,
        address _debitToken,
        address _creditToken,
        uint256 _amount,
        uint256 _minAmountOut
    ) external payable returns (uint256 _amountOut);
}
