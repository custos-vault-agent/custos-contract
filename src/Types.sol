// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Status agent on-chain (spec D6).
/// @dev `None` sengaja di indeks 0 supaya slot kosong tidak terbaca sebagai Active.
enum Status {
    None,
    Active,
    Paused,
    Revoked
}

/// @notice Catatan satu agent. Urutan field ditentukan oleh packing, bukan estetika.
/// @dev Layout slot (spec §3.3) — jangan diubah urutannya setelah deploy:
///        0: name
///        1: wallet (160) + status (8)
///        2: owner  (160)
///        3: allowance (128) + usedInPeriod (128)
///        4: reserved (128) + periodStart (64) + periodLength (32)
///        5: descriptionHash
///        6: registeredAt (64)
///
///      `reserved` selalu 0 di MVP (invarian I5). Ia dideklarasikan sekarang karena
///      field struct hanya bisa ditambahkan di ujung: kalau baru ditambah saat limit
///      order masuk di v1.1, ia mendarat di slot 7 dan packing slot 4 hilang selamanya.
///      Sebuah uint128 yang bernilai nol tidak memakan gas.
struct Agent {
    bytes32 name;
    address wallet;
    Status status;
    address owner;
    uint128 allowance;
    uint128 usedInPeriod;
    uint128 reserved;
    uint64 periodStart;
    uint32 periodLength;
    bytes32 descriptionHash;
    uint64 registeredAt;
}
