// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @custom:storage-location erc7201:custos.storage.vault
struct VaultLayout {
    /// @dev Saldo per pemilik per token. Sumber kebenaran satu-satunya.
    mapping(address owner => mapping(address token => uint256 amount)) balance;
    /// @dev Σ balance[*][token]. Dasar verifikasi deposit di `creditDeposit`:
    ///      delta = IERC20(token).balanceOf(proxy) - totalTracked[token].
    ///      Karena delta diukur, bukan dilaporkan, pemanggil tidak bisa berbohong.
    mapping(address token => uint256 amount) totalTracked;
}

library VaultStorage {
    /// @dev keccak256(abi.encode(uint256(keccak256("custos.storage.vault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT = 0xdbdda7defa1da7a3eccbfd1504f172548b29af7b06dbd695dd408a21181c1700;

    function layout() internal pure returns (VaultLayout storage $) {
        assembly {
            $.slot := SLOT
        }
    }
}
