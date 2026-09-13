// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Agent} from "../Types.sol";

/// @custom:storage-location erc7201:custos.storage.agents
struct AgentLayout {
    /// @dev id = keccak256(abi.encode(owner, wallet)).
    mapping(bytes32 id => Agent agent) agents;
    /// @dev Ikatan wallet→agent bersifat 1:1 dan permanen, bahkan setelah revoke
    ///      (spec D8). Tidak pernah dihapus, sehingga sebuah wallet yang pernah
    ///      dicabut tidak bisa didaftarkan ulang oleh siapa pun.
    mapping(address wallet => bytes32 id) idOfWallet;
    /// @dev Hanya agent hidup (Active|Paused). Revoke menghapusnya dari sini supaya
    ///      loop `delegatedOf` tetap terbatas dan slot kuota owner ikut bebas.
    ///      Riwayat lengkap tetap ada di `index` dan di event.
    mapping(address owner => bytes32[] ids) agentsOfOwner;
    /// @dev Direktori publik, append-only. Tidak pernah menyusut.
    bytes32[] index;
}

library AgentStorage {
    /// @dev keccak256(abi.encode(uint256(keccak256("custos.storage.agents")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT = 0xe5ca5812768101473435d82f25f61a664feea0baabdf82694bf0e670d91ef600;

    function layout() internal pure returns (AgentLayout storage $) {
        assembly {
            $.slot := SLOT
        }
    }
}
