// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IVaultFactory {
    function deploy(
        bytes32 agentId,
        address creator,
        address agent,
        address asset,
        address priceOracle,
        address yieldSource,
        uint16 feeRate,
        uint16 maxDrawdownBps,
        uint16 maxUtilizationBps,
        uint128 allowance,
        uint32 periodLength,
        bytes32 name
    ) external returns (address vault);
}
