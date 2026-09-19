// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The slice of Chainlink's `EACAggregatorProxy` that `PriceOracle` uses.
///         Copied rather than imported — four functions.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    /// @dev A real Chainlink proxy always has an aggregator behind it; zero means it is not one.
    function aggregator() external view returns (address);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
