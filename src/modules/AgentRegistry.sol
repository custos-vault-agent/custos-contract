// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AccessControl} from "./AccessControl.sol";
import {AccessLayout, AccessStorage} from "../storage/AccessStorage.sol";
import {AgentRecord, Status} from "../Types.sol";
import {RegistryLayout, RegistryStorage} from "../storage/RegistryStorage.sol";
import {AgentVault} from "../AgentVault.sol";
import {IMarket} from "../interfaces/IMarket.sol";
import {IVaultFactory} from "../interfaces/IVaultFactory.sol";
import {
    AgentAlreadyRevoked,
    DrawdownOutOfRange,
    FeeRateOutOfRange,
    MarketQuoteMismatch,
    NotCreator,
    SeedTooSmall,
    SelfDelegation,
    UnknownAgent,
    UtilizationOutOfRange,
    WalletAlreadyBound,
    YieldSourceNotAllowed,
    ZeroAddress
} from "../Errors.sol";
import {
    AgentAllowanceChanged,
    AgentPeriodChanged,
    AgentPublicChanged,
    AgentRegistered,
    AgentStatusChanged,
    MarketAllowedChanged
} from "../Events.sol";

/// @notice Agent registry. Metadata lives here; funds and trading live in each
///         agent's `AgentVault`.
///
/// @dev Every function here is signed by the creator, never by the agent.
abstract contract AgentRegistry is AccessControl {
    using SafeERC20 for IERC20;

    /// @param yieldSource `address(0)` disables idle yield for this vault (D22).
    /// @param seedAmount Must be `>= minSeed` (D15); locked forever at `address(1)`.
    /// @dev `nonReentrant` is load-bearing: `yieldSource` is caller-chosen and gets
    ///      called via `factory.deploy` -> `seedDeposit` -> `_pushToYield` before the
    ///      wallet binding below is written. Without the guard a malicious yield
    ///      source could reenter with the same `wallet` and register two vaults for
    ///      one id, corrupting `$.index`/`$.agentsOfCreator`.
    function registerAgent(
        bytes32 name,
        string calldata description,
        address wallet,
        uint128 allowance,
        uint32 periodLength,
        uint16 feeRate,
        uint16 maxDrawdownBps,
        address yieldSource,
        uint16 maxUtilizationBps,
        bool isPublic,
        uint128 seedAmount
    ) external nonReentrant whenNotPaused returns (bytes32 id, address vault) {
        if (wallet == address(0)) revert ZeroAddress();
        // A creator's own wallet as agent would be locked out of its own vault by
        // `onlyAgent` — it could never act as an ordinary subscriber.
        if (wallet == msg.sender) revert SelfDelegation();
        if (feeRate > 5000) revert FeeRateOutOfRange();
        if (maxDrawdownBps > 5000) revert DrawdownOutOfRange();
        if (maxUtilizationBps < 1000 || maxUtilizationBps > 9500) revert UtilizationOutOfRange();

        AccessLayout storage access = AccessStorage.layout();
        // L1: a zero seed must never pass, even before minSeed is configured.
        if (seedAmount == 0 || seedAmount < access.minSeed) revert SeedTooSmall();
        // H1: the yield source receives the vault's whole idle balance — allowlisted only.
        if (yieldSource != address(0) && !access.allowedYieldSources[yieldSource]) {
            revert YieldSourceNotAllowed();
        }

        RegistryLayout storage $ = RegistryStorage.layout();
        // Permanent binding (D8): a wallet used once can never be registered again.
        if ($.idOfWallet[wallet] != bytes32(0)) revert WalletAlreadyBound();

        id = keccak256(abi.encode(msg.sender, wallet));

        vault = IVaultFactory(access.vaultFactory)
            .deploy(
                id,
                msg.sender,
                wallet,
                access.accountingAsset,
                access.priceOracle,
                yieldSource,
                feeRate,
                maxDrawdownBps,
                maxUtilizationBps,
                allowance,
                periodLength,
                name
            );

        // Transfer first, then have the vault record it.
        IERC20(access.accountingAsset).safeTransferFrom(msg.sender, vault, seedAmount);
        AgentVault(vault).seedDeposit(seedAmount);

        $.agents[id] = AgentRecord({
            name: name,
            wallet: wallet,
            status: Status.Active,
            creator: msg.sender,
            vault: vault,
            descriptionHash: keccak256(bytes(description)),
            feeRate: feeRate,
            isPublic: isPublic,
            registeredAt: uint64(block.timestamp)
        });
        $.idOfWallet[wallet] = id;
        $.agentsOfCreator[msg.sender].push(id);
        $.index.push(id);

        emit AgentRegistered(
            id, msg.sender, wallet, vault, name, description, allowance, periodLength, feeRate, isPublic
        );
    }

    function pauseAgent(bytes32 id) external {
        _setStatus(id, Status.Paused);
    }

    function resumeAgent(bytes32 id) external {
        _setStatus(id, Status.Active);
    }

    /// @notice Permanently revokes an agent. The record is never deleted — the public
    ///         directory is append-only and the wallet binding is kept.
    function revokeAgent(bytes32 id) external {
        _setStatus(id, Status.Revoked);
    }

    function setAllowance(bytes32 id, uint128 newAllowance) external {
        AgentRecord storage a = _ownedAgent(id);
        emit AgentAllowanceChanged(id, AgentVault(a.vault).allowance(), newAllowance);
        AgentVault(a.vault).setAllowance(newAllowance);
    }

    function setPeriod(bytes32 id, uint32 periodLength) external {
        AgentRecord storage a = _ownedAgent(id);
        emit AgentPeriodChanged(id, AgentVault(a.vault).periodLength(), periodLength);
        AgentVault(a.vault).setPeriod(periodLength);
    }

    /// @notice D16: marketplace visibility only. On-chain stays permissionless —
    ///         vault `deposit` is never gated by `isPublic`.
    function setPublic(bytes32 id, bool isPublic) external {
        AgentRecord storage a = _ownedAgent(id);
        a.isPublic = isPublic;
        emit AgentPublicChanged(id, isPublic);
    }

    /// @notice Allows or disallows a market for one vault. Protocol-gated: D4 (quote
    ///         must be USDC) is a safety invariant of the allowance model, not a
    ///         creator choice.
    function setMarketAllowed(bytes32 id, address market, bool allowed) external onlyUpgradeAuthority {
        AgentRecord storage a = RegistryStorage.layout().agents[id];
        if (a.status == Status.None) revert UnknownAgent();
        if (allowed && IMarket(market).quoteToken() != AccessStorage.layout().accountingAsset) {
            revert MarketQuoteMismatch();
        }
        // H2: the vault itself rejects a market whose base has no feed (NoPriceFeed).
        AgentVault(a.vault).setMarketAllowed(market, allowed);
        emit MarketAllowedChanged(market, allowed);
    }

    /// @notice Credits a cross-chain deposit from the Aurora Receiver as a plain
    ///         ERC-4626 deposit into the target vault.
    /// @dev The Aurora Receiver is the only caller trusted to know the subscriber and
    ///      amount from the source chain (spec v1 §11 O1). Funds are pulled here first,
    ///      then forwarded through the normal `deposit()`.
    function creditDeposit(bytes32 agentId, address subscriber, uint256 assets)
        external
        onlyAuroraReceiver
        whenNotPaused
        returns (uint256 shares)
    {
        AgentRecord storage a = RegistryStorage.layout().agents[agentId];
        if (a.status == Status.None) revert UnknownAgent();

        address token = AccessStorage.layout().accountingAsset;
        IERC20(token).safeTransferFrom(msg.sender, address(this), assets);
        IERC20(token).forceApprove(a.vault, assets);
        shares = AgentVault(a.vault).deposit(assets, subscriber);
    }

    /* ------------------------------ internal ----------------------------- */

    function _ownedAgent(bytes32 id) internal view returns (AgentRecord storage a) {
        a = RegistryStorage.layout().agents[id];
        if (a.status == Status.None) revert UnknownAgent();
        if (a.creator != msg.sender) revert NotCreator();
    }

    /// @dev D19: revoke is permanent — no transition out of Revoked, including
    ///      pause/resume/re-revoke.
    function _setStatus(bytes32 id, Status next) internal {
        AgentRecord storage a = _ownedAgent(id);
        if (a.status == Status.Revoked) revert AgentAlreadyRevoked();
        emit AgentStatusChanged(id, a.status, next);
        a.status = next;
        AgentVault(a.vault).setStatus(next);
    }

    /* ------------------------------- views ------------------------------- */

    function getAgent(bytes32 id) external view returns (AgentRecord memory) {
        return RegistryStorage.layout().agents[id];
    }

    function agentIdOf(address wallet) external view returns (bytes32) {
        return RegistryStorage.layout().idOfWallet[wallet];
    }

    function agentsOfCreator(address creator) external view returns (bytes32[] memory) {
        return RegistryStorage.layout().agentsOfCreator[creator];
    }

    function agentCount() external view returns (uint256) {
        return RegistryStorage.layout().index.length;
    }

    function agentAt(uint256 i) external view returns (bytes32) {
        return RegistryStorage.layout().index[i];
    }

    function agentExists(bytes32 id) external view returns (bool) {
        return RegistryStorage.layout().agents[id].status != Status.None;
    }
}
