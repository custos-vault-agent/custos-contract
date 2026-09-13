// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AgentVault} from "../AgentVault.sol";

/// @notice Deploy `AgentVault` lewat `create2`. Fungsi `internal` — hanya bisa
///         dipanggil dari kontrak yang mewarisinya, tidak pernah dari luar.
///
/// @dev `salt = agentId` membuat alamat vault deterministik dan bisa dihitung
///      off-chain sebelum transaksi register dikirim (spec v1 §4.4).
abstract contract VaultFactory {
    function _deployVault(
        bytes32 agentId,
        address creator,
        address agent,
        address asset,
        address marketAdapter,
        address yieldSource,
        uint16 feeRate,
        uint16 maxDrawdownBps,
        uint16 maxUtilizationBps,
        uint128 allowance,
        uint32 periodLength,
        bytes32 name
    ) internal returns (address vault) {
        (string memory tokenName, string memory tokenSymbol) = _tokenNames(name, agentId);
        vault = address(
            new AgentVault{salt: agentId}(
                agentId,
                creator,
                agent,
                address(this),
                asset,
                marketAdapter,
                yieldSource,
                feeRate,
                maxDrawdownBps,
                maxUtilizationBps,
                allowance,
                periodLength,
                tokenName,
                tokenSymbol
            )
        );
    }

    /// @dev `name` disimpan on-chain sebagai `bytes32` (D9) tapi ERC-20 butuh
    ///      `string` — dikonversi di sini, sekali, saat deploy, bukan setiap kali
    ///      token metadata dibaca.
    function _tokenNames(bytes32 name, bytes32 agentId)
        internal
        pure
        returns (string memory tokenName, string memory tokenSymbol)
    {
        tokenName = string.concat("Custos: ", _bytes32ToString(name));
        tokenSymbol = string.concat("cst-", _toHexShort(agentId));
    }

    function _bytes32ToString(bytes32 data) internal pure returns (string memory) {
        uint256 len;
        while (len < 32 && data[len] != 0) len++;
        bytes memory result = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            result[i] = data[i];
        }
        return string(result);
    }

    /// @dev 4 byte pertama dari agentId, hex, tanpa prefix "0x" — cukup unik untuk
    ///      simbol token yang dibaca manusia, tidak diklaim sebagai tabrakan-bebas.
    function _toHexShort(bytes32 data) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory result = new bytes(8);
        for (uint256 i = 0; i < 4; i++) {
            result[i * 2] = alphabet[uint8(data[i] >> 4)];
            result[i * 2 + 1] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(result);
    }
}
