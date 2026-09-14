// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {AccessStorage} from "../src/storage/AccessStorage.sol";
import {RegistryStorage} from "../src/storage/RegistryStorage.sol";
import {NansenStorage} from "../src/storage/NansenStorage.sol";

/// @notice Konstanta slot ERC-7201 di-hardcode karena `assembly { $.slot := X }`
///         hanya menerima konstanta. Test ini menurunkan ulang setiap slot dari
///         rumusnya dan menutup kelas bug "salah ketik satu digit, baru ketahuan
///         setelah ada dana di dalamnya".
contract SlotsTest is Test {
    function _erc7201(string memory id) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff));
    }

    function test_slotsMatchSpec() public pure {
        assertEq(AccessStorage.SLOT, _erc7201("custos.storage.access"), "access");
        assertEq(RegistryStorage.SLOT, _erc7201("custos.storage.registry"), "registry");
        assertEq(NansenStorage.SLOT, _erc7201("custos.storage.nansen"), "nansen");
    }

    /// @notice ERC-7201 mensyaratkan slot kelipatan 256 supaya kompatibel dengan
    ///         rencana Verkle.
    function test_slotsAre256Aligned() public pure {
        assertEq(uint256(AccessStorage.SLOT) & 0xff, 0);
        assertEq(uint256(RegistryStorage.SLOT) & 0xff, 0);
        assertEq(uint256(NansenStorage.SLOT) & 0xff, 0);
    }

    /// @notice Setiap namespace harus benar-benar terpisah.
    function test_slotsAreDistinct() public pure {
        assertTrue(AccessStorage.SLOT != RegistryStorage.SLOT, "access/registry bentrok");
        assertTrue(AccessStorage.SLOT != NansenStorage.SLOT, "access/nansen bentrok");
        assertTrue(RegistryStorage.SLOT != NansenStorage.SLOT, "registry/nansen bentrok");
    }
}
