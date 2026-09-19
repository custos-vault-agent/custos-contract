// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The market shape Custos expects.
///
/// @dev Not Kuru's interface. Custos speaks its own shape so a thin adapter can wrap
///      any venue without touching the allowance logic.
interface IMarket {
    function baseToken() external view returns (address);

    function quoteToken() external view returns (address);

    /// @notice Market order. Pulls `amountIn` from the caller and sends the output back.
    /// @param isBuy True: `amountIn` is quote, output is base. False: the reverse.
    /// @param minAmountOut Slippage bound; implementations must revert if not met.
    function swap(bool isBuy, uint256 amountIn, uint256 minAmountOut) external returns (uint256 amountOut);
}
