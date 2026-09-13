// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @custom:storage-location erc7201:custos.storage.trading
/// @dev v1.1 menambahkan `orders`, `orderIdOfKuru`, dan `orderNonce` di ujung struct
///      ini ketika limit order masuk — tanpa migrasi, tanpa menyentuh saldo.
struct TradingLayout {
    /// @dev Market wajib ber-quote token == accountingAsset (spec D4), diperiksa
    ///      saat allowlist, bukan saat swap.
    mapping(address market => bool allowed) allowedMarkets;
}

library TradingStorage {
    /// @dev keccak256(abi.encode(uint256(keccak256("custos.storage.trading")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT = 0xa1de9282be38f019686c6ed5570e8f558ca2edaf04edf1087d33e75bdd389900;

    function layout() internal pure returns (TradingLayout storage $) {
        assembly {
            $.slot := SLOT
        }
    }
}
