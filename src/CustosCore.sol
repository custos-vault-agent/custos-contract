// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AgentRegistry} from "./modules/AgentRegistry.sol";
import {NansenAttestation} from "./modules/NansenAttestation.sol";

/// @title Custos — registry dan vault factory untuk trading lintas rantai di Kuru.
///
/// @dev Satu kontrak implementation. Perbedaan terbesar dari v0.1 (`CustosLogic`):
///      dana dan trading tidak lagi hidup di sini sama sekali — setiap agent punya
///      `AgentVault` sendiri, immutable, di-deploy lewat `VaultFactory`. CustosCore
///      yang tersisa murni registry + otorisasi + Nansen attestation.
contract CustosCore is NansenAttestation, AgentRegistry {
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
