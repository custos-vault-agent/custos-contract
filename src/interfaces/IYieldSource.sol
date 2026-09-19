// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Yield source adapter shape AgentVault expects (spec v1 §4.8).
///
/// @dev Adapter pattern, like `IMarket`: integrating a different lending protocol
///      never touches vault logic.
interface IYieldSource {
    /// @notice Deposits `assets` for the caller. Caller must have approved.
    function deposit(uint256 assets) external returns (uint256 deposited);

    /// @notice Withdraws up to `assets` for the caller. May return less than requested
    ///         if the caller's position is smaller.
    function withdraw(uint256 assets) external returns (uint256 withdrawn);

    /// @notice Caller's current position, including accrued yield.
    function balanceOf(address account) external view returns (uint256);
}
