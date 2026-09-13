// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Bentuk adapter yield source yang diharapkan AgentVault (spec v1 §4.8).
///
/// @dev Pola adapter, sama seperti `IMarket`: AgentVault berbicara dengan bentuknya
///      sendiri, bukan antarmuka lending protocol tertentu, supaya integrasi ke
///      protokol yang berbeda tidak pernah menyentuh logika vault.
interface IYieldSource {
    /// @notice Setor `assets` atas nama pemanggil. Pemanggil harus sudah approve.
    function deposit(uint256 assets) external returns (uint256 deposited);

    /// @notice Tarik sampai `assets` milik pemanggil. Boleh mengembalikan kurang dari
    ///         yang diminta kalau posisi pemanggil lebih kecil — AgentVault menangani
    ///         itu dengan meminta hanya sebesar yang ia butuhkan.
    function withdraw(uint256 assets) external returns (uint256 withdrawn);

    /// @notice Nilai posisi pemanggil saat ini, termasuk yield yang sudah bertambah.
    function balanceOf(address account) external view returns (uint256);
}
