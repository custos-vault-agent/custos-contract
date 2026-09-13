// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CustosLogic} from "../../src/CustosLogic.sol";
import {AgentStorage} from "../../src/storage/AgentStorage.sol";

/// @notice Berdiri untuk v1.1. Yang diuji bukan fiturnya melainkan klaim arsitekturnya:
///         menambah state dan perilaku tidak boleh menggeser satu pun field lama.
contract CustosLogicV2 is CustosLogic {
    function version() external pure override returns (string memory) {
        return "2.0.0";
    }

    /// @dev Fungsi baru yang hanya ada setelah upgrade.
    function agentOwnerOf(bytes32 id) external view returns (address) {
        return AgentStorage.layout().agents[id].owner;
    }
}
