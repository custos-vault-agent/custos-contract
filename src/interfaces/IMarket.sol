// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Bentuk pasar yang diharapkan Custos.
///
/// @dev Ini bukan antarmuka Kuru. Custos sengaja berbicara dengan bentuknya sendiri
///      supaya modul trading bisa selesai dan teruji sebelum detail Kuru final; sebuah
///      adapter tipis yang membungkus orderbook Kuru akan mengisi antarmuka ini
///      (langkah 7). Konsekuensi lain: menambah venue kedua kelak tidak menyentuh
///      logika allowance sama sekali.
interface IMarket {
    function baseToken() external view returns (address);

    function quoteToken() external view returns (address);

    /// @notice Market order. Menarik `amountIn` dari pemanggil dan mengirim hasilnya balik.
    /// @param isBuy True: `amountIn` dalam quote, hasil dalam base. False: kebalikannya.
    /// @param minAmountOut Batas slippage; implementasi harus revert bila tak tercapai.
    function swap(bool isBuy, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut);
}
