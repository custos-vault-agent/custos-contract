// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AgentRecord} from "../Types.sol";

/// @custom:storage-location erc7201:custos.storage.registry
struct RegistryLayout {
    /// @dev id = keccak256(abi.encode(creator, wallet)).
    mapping(bytes32 id => AgentRecord agent) agents;
    /// @dev Ikatan wallet→agent bersifat 1:1 dan permanen, bahkan setelah revoke
    ///      (spec D8). Tidak pernah dihapus.
    mapping(address wallet => bytes32 id) idOfWallet;
    /// @dev Direktori per creator. Tidak pernah dipangkas — beda dari v0.1's
    ///      `agentsOfOwner`, yang menghapus entry saat revoke supaya loop
    ///      `_delegatedOf` tetap pendek. Loop itu tidak ada lagi di v1 (akuntansi
    ///      per-vault): array ini murni direktori, jadi menyusutkannya saat revoke
    ///      cuma menghapus riwayat tanpa alasan.
    mapping(address creator => bytes32[] ids) agentsOfCreator;
    /// @dev Direktori publik, append-only.
    bytes32[] index;
}

/// @dev Namespace baru ("custos.storage.registry") menggantikan
///      "custos.storage.agents" — bukan sekadar rename kosmetik: struct yang
///      disimpannya (`AgentRecord`) sudah berbeda bentuk dari `Agent` lama
///      (field `owner`→`creator`, tambah `vault`/`feeRate`/`isPublic`/nansen
///      fields). Namespace lama tidak dipakai ulang supaya slot yang sudah
///      ditulis v0.1 (kalau pernah di-deploy) tidak pernah dibaca ulang dengan
///      layout yang salah.
library RegistryStorage {
    /// @dev keccak256(abi.encode(uint256(keccak256("custos.storage.registry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT = 0x20679b6953b0fa380593911fc601d4c8bc0c37be551ac1b3181d2fbbc3d76800;

    function layout() internal pure returns (RegistryLayout storage $) {
        assembly {
            $.slot := SLOT
        }
    }
}
