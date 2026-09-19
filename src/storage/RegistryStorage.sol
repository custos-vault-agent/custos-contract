// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AgentRecord} from "../Types.sol";

/// @custom:storage-location erc7201:custos.storage.registry
struct RegistryLayout {
    /// @dev id = keccak256(abi.encode(creator, wallet)).
    mapping(bytes32 id => AgentRecord agent) agents;
    /// @dev Wallet→agent binding is 1:1 and permanent, even after revoke (spec D8).
    mapping(address wallet => bytes32 id) idOfWallet;
    /// @dev Per-creator directory; never pruned, even on revoke.
    mapping(address creator => bytes32[] ids) agentsOfCreator;
    /// @dev Public directory, append-only.
    bytes32[] index;
}

/// @dev Namespace "custos.storage.registry" replaces v0.1's "custos.storage.agents":
///      the stored struct changed shape, so the old slots must never be re-read with
///      the new layout.
library RegistryStorage {
    /// @dev keccak256(abi.encode(uint256(keccak256("custos.storage.registry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT = 0x20679b6953b0fa380593911fc601d4c8bc0c37be551ac1b3181d2fbbc3d76800;

    function layout() internal pure returns (RegistryLayout storage $) {
        assembly {
            $.slot := SLOT
        }
    }
}
