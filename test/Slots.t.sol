// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {AccessStorage} from "../src/storage/AccessStorage.sol";
import {AgentStorage} from "../src/storage/AgentStorage.sol";
import {TradingStorage} from "../src/storage/TradingStorage.sol";
import {VaultStorage} from "../src/storage/VaultStorage.sol";

/// @notice Konstanta slot ERC-7201 di-hardcode karena `assembly { $.slot := X }`
///         hanya menerima konstanta. Salah ketik satu digit tidak akan gagal saat
///         compile maupun deploy, dan baru ketahuan setelah ada dana di dalamnya.
///         Test ini menurunkan ulang setiap slot dari rumusnya dan menutup seluruh
///         kelas bug tersebut.
contract SlotsTest is Test {
    function _erc7201(string memory id) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff));
    }

    function test_slotsMatchSpec() public pure {
        assertEq(AccessStorage.SLOT, _erc7201("custos.storage.access"), "access");
        assertEq(VaultStorage.SLOT, _erc7201("custos.storage.vault"), "vault");
        assertEq(AgentStorage.SLOT, _erc7201("custos.storage.agents"), "agents");
        assertEq(TradingStorage.SLOT, _erc7201("custos.storage.trading"), "trading");
    }

    /// @notice ERC-7201 mensyaratkan slot kelipatan 256 supaya kompatibel dengan
    ///         rencana Verkle. Kalau masking `& ~0xff` hilang, test ini yang jatuh.
    function test_slotsAre256Aligned() public pure {
        assertEq(uint256(AccessStorage.SLOT) & 0xff, 0);
        assertEq(uint256(VaultStorage.SLOT) & 0xff, 0);
        assertEq(uint256(AgentStorage.SLOT) & 0xff, 0);
        assertEq(uint256(TradingStorage.SLOT) & 0xff, 0);
    }

    /// @notice Empat namespace harus benar-benar terpisah. Dua slot yang sama berarti
    ///         dua struct saling menimpa.
    function test_slotsAreDistinct() public pure {
        bytes32[4] memory s =
            [AccessStorage.SLOT, VaultStorage.SLOT, AgentStorage.SLOT, TradingStorage.SLOT];
        for (uint256 i = 0; i < 4; i++) {
            for (uint256 j = i + 1; j < 4; j++) {
                assertTrue(s[i] != s[j], "slot bentrok");
            }
        }
    }
}
