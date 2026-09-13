// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CustosCore} from "../../src/CustosCore.sol";
import {RegistryStorage} from "../../src/storage/RegistryStorage.sol";

/// @notice Berdiri untuk v3 hipotetis. Yang diuji bukan fiturnya melainkan klaim
///         arsitekturnya: menambah state dan perilaku tidak boleh menggeser satu pun
///         field lama di RegistryStorage/AccessStorage, dan tidak boleh menyentuh
///         AgentVault yang sudah di-deploy sama sekali.
contract CustosCoreV2 is CustosCore {
    function version() external pure override returns (string memory) {
        return "3.0.0";
    }

    /// @dev Fungsi baru yang hanya ada setelah upgrade.
    function creatorOf(bytes32 id) external view returns (address) {
        return RegistryStorage.layout().agents[id].creator;
    }
}
