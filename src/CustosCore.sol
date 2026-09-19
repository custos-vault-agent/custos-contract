// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AgentRegistry} from "./modules/AgentRegistry.sol";

/// @title Custos — agent registry for cross-chain trading on Kuru.
///
/// @dev Single UUPS implementation. No funds or trading live here: every agent has
///      its own immutable `AgentVault`, deployed through `VaultFactory`. What remains
///      is registry + authorization.
contract CustosCore is AgentRegistry {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address upgradeAuthority_, address accountingAsset_) external initializer {
        __AccessControl_init(upgradeAuthority_, accountingAsset_);
    }

    function version() external pure virtual returns (string memory) {
        return "2.0.0";
    }
}
