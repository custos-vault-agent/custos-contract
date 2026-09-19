// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Oracle shape AgentVault uses to value held base tokens (H2). Adapter
///         pattern, like `IMarket`.
interface IPriceOracle {
    /// @notice Denomination of `valueOf`; must equal the accounting asset.
    function quoteToken() external view returns (address);

    function hasFeed(address token) external view returns (bool);

    /// @notice Value of `amount` of `token` in the quote token. Reverts if the feed is
    ///         missing, stale, or non-positive.
    function valueOf(address token, uint256 amount) external view returns (uint256);
}
