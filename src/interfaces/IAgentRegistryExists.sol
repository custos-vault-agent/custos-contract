// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The one view NansenModule needs from the registry — kept minimal
///         so it never couples to AgentRecord's internal layout.
interface IAgentRegistryExists {
    function agentExists(bytes32 id) external view returns (bool);
}
