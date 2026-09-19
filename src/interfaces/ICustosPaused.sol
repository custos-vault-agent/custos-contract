// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The one view AgentVault reads from CustosCore: the protocol-wide pause (M4).
interface ICustosPaused {
    function paused() external view returns (bool);
}
