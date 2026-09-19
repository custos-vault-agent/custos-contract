// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AgentVault} from "./AgentVault.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {OnlyCustosCore, ZeroAddress} from "./Errors.sol";

/// @notice Deploys `AgentVault` via `create2`. A standalone contract, not a module
///         inherited by CustosCore: AgentVault's ~13 KB initcode is embedded in
///         whichever contract calls `new AgentVault`, which pushed CustosCore over
///         EIP-170.
///
/// @dev Not upgradeable. When AgentVault changes, deploy a new factory and call
///      `CustosCore.setVaultFactory`; existing vaults are untouched.
///
///      `salt = agentId` makes vault addresses deterministic (spec v1 §4.4), based on
///      this factory's address. `onlyCore` stops anyone deploying orphan vaults with
///      the same salt; the vault's `custosCore` is always `msg.sender` = the proxy.
contract VaultFactory is IVaultFactory {
    address public immutable core;

    constructor(address core_) {
        if (core_ == address(0)) revert ZeroAddress();
        core = core_;
    }

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
    ) external returns (address vault) {
        if (msg.sender != core) revert OnlyCustosCore();
        (string memory tokenName, string memory tokenSymbol) = _tokenNames(name, agentId);
        vault = address(
            new AgentVault{salt: agentId}(
                agentId,
                creator,
                agent,
                msg.sender,
                asset,
                priceOracle,
                yieldSource,
                feeRate,
                maxDrawdownBps,
                maxUtilizationBps,
                allowance,
                periodLength,
                tokenName,
                tokenSymbol
            )
        );
    }

    /// @dev `name` is stored as `bytes32` (D9) but ERC-20 wants `string`; converted
    ///      once at deploy.
    function _tokenNames(bytes32 name, bytes32 agentId)
        internal
        pure
        returns (string memory tokenName, string memory tokenSymbol)
    {
        tokenName = string.concat("Custos: ", _bytes32ToString(name));
        tokenSymbol = string.concat("cst-", _toHexShort(agentId));
    }

    function _bytes32ToString(bytes32 data) internal pure returns (string memory) {
        uint256 len = 0;
        while (len < 32 && data[len] != 0) len++;
        bytes memory result = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            result[i] = data[i];
        }
        return string(result);
    }

    /// @dev First 4 bytes of agentId as hex, no "0x" — unique enough for a symbol,
    ///      not claimed collision-free.
    function _toHexShort(bytes32 data) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory result = new bytes(8);
        for (uint256 i = 0; i < 4; i++) {
            result[i * 2] = alphabet[uint8(data[i] >> 4)];
            result[i * 2 + 1] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(result);
    }
}
