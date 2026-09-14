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

/// @notice Catatan satu agent di registry. Vault-nya terpisah (AgentVault), bukan
///         bagian dari struct ini — lihat spec v1 D13. Nansen attestation juga
///         terpisah (NansenModule), bukan bagian dari struct ini — lihat
///         docs/superpowers/specs/2026-09-14-nansen-module-split-design.md.
/// @dev Layout slot (spec v1 §3.1) — jangan diubah urutannya setelah deploy:
///        0: name
///        1: wallet (160) + status (8)
///        2: creator
///        3: vault
///        4: descriptionHash
///        5: feeRate (16) + isPublic (8) + registeredAt (64)
struct AgentRecord {
    bytes32 name;
    address wallet;
    Status status;
    address creator;
    address vault;
    bytes32 descriptionHash;
    uint16 feeRate;
    bool isPublic;
    uint64 registeredAt;
}
