// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AgentRecord} from "../Types.sol";

/// @notice The one view NansenModule needs from the registry: the record, to bind an
///         attestation to the agent's creator wallet.
interface IAgentRegistry {
    function getAgent(bytes32 id) external view returns (AgentRecord memory);
}
