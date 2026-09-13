// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @custom:storage-location erc7201:custos.storage.access
struct AccessLayout {
    address upgradeAuthority; // multisig + timelock (D10)
    address auroraReceiver; // pemanggil creditDeposit
    address attestor; // wallet yang sign Nansen attestation (D23)
    address accountingAsset; // USDC (D4)
    address marketAdapter; // KuruMarketAdapter — renamed dari `kuru`
    uint128 minSeed; // minimum seed deposit creator (D15)
    bool paused; // emergency stop
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
