// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @custom:storage-location erc7201:custos.storage.access
struct AccessLayout {
    /// @dev Multisig 2-of-3 + Timelock (spec D10). Satu-satunya yang boleh upgrade.
    address upgradeAuthority;
    /// @dev Satu-satunya pemanggil `creditDeposit` yang sah (spec §4.2).
    address auroraReceiver;
    /// @dev Router Kuru. Belum dipakai di MVP — `executeSwap` memanggil market
    ///      langsung — tapi dideklarasikan sekarang dengan alasan yang sama seperti
    ///      `Agent.reserved`: field hanya bisa ditambah di ujung struct.
    address kuru;
    /// @dev USDC. Unit tunggal untuk allowance dan delegasi (spec D4).
    address accountingAsset;
    /// @dev Emergency stop. Memblokir deposit, registrasi, dan trading.
    bool paused;
}

library AccessStorage {
    /// @dev keccak256(abi.encode(uint256(keccak256("custos.storage.access")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT = 0xcc91b5d1a184883f7b0a5f92bd85bc7c7bd78970bafd3823ff921c9c140d6b00;

    function layout() internal pure returns (AccessLayout storage $) {
        assembly {
            $.slot := SLOT
        }
    }
}
