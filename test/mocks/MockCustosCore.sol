// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Stands in for CustosCore in vault unit tests: only the `paused()` view
///         AgentVault reads (M4). Tests prank this address as msg.sender for
///         onlyCustosCore calls.
contract MockCustosCore {
    bool public paused;

    function setPaused(bool p) external {
        paused = p;
    }
}
