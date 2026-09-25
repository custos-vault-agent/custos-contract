// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The two functions a wrapped native token adds to ERC-20 (WMON, WETH).
interface IWrappedNative {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
