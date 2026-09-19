// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @custom:storage-location erc7201:custos.storage.access
struct AccessLayout {
    address upgradeAuthority; // multisig + timelock (D10)
    address __gap0; // was auroraReceiver; cross-chain deposits now call AgentVault.deposit directly
    address accountingAsset; // USDC (D4)
    address marketAdapter; // KuruMarketAdapter
    uint128 minSeed; // creator's minimum seed deposit (D15)
    bool paused; // emergency stop
    // --- added after the security review; append-only, never insert above ---
    address priceOracle; // PriceOracle (H2) — frozen into each vault at deploy
    mapping(address yieldSource => bool allowed) allowedYieldSources; // H1
    address vaultFactory; // standalone VaultFactory — AgentVault initcode is no longer in CustosCore
    address nansigil; // INanSigil: creator reputation, looked up by wallet
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
