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
import {INanSigil} from "nansigil-contract/interfaces/INanSigil.sol";
import {
    AgentAlreadyRevoked,
    DrawdownOutOfRange,
    FeeRateOutOfRange,
    MarketNotCurated,
    MarketQuoteMismatch,
    MarketStillHeld,
    NotCreator,
    SeedTooSmall,
    SelfDelegation,
    TooManyCuratedMarkets,
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
    AgentMarketChanged
} from "../Events.sol";

/// @notice Agent registry. Metadata lives here; funds and trading live in each
///         agent's `AgentVault`.
///
/// @dev Every function here is signed by the creator, never by the agent.
abstract contract AgentRegistry is AccessControl {
    using SafeERC20 for IERC20;

    /// @param yieldSource `address(0)` disables idle yield for this vault (D22).
    /// @param seedAmount Must be `>= minSeed` (D15); locked forever at `address(1)`.
    /// @param markets Curated markets to allow on the new vault, so one transaction
    ///        leaves the agent able to trade. May be empty; the creator can add them
    ///        later with `setAgentMarket`.
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
        uint128 seedAmount,
        address[] calldata markets
    ) external nonReentrant whenNotPaused returns (bytes32 id, address vault) {
        if (wallet == address(0)) revert ZeroAddress();
        // A creator's own wallet as agent would be locked out of its own vault by
        // `onlyAgent` — it could never act as an ordinary subscriber.
        if (wallet == msg.sender) revert SelfDelegation();
        if (feeRate > 5000) revert FeeRateOutOfRange();
        if (maxDrawdownBps > 5000) revert DrawdownOutOfRange();
        if (maxUtilizationBps < 1000 || maxUtilizationBps > 9500) revert UtilizationOutOfRange();
        if (markets.length > MAX_CURATED_MARKETS) revert TooManyCuratedMarkets();

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

        // After AgentRegistered, so a reader sees the agent before its markets. Only
        // curated markets, so registration cannot smuggle in an arbitrary callee of
        // executeSwap; the vault rejects a base with no price feed (H2).
        for (uint256 i = 0; i < markets.length; i++) {
            if (!_isCurated(markets[i])) revert MarketNotCurated();
            AgentVault(vault).setMarketAllowed(markets[i], true);
            emit AgentMarketChanged(id, markets[i], true);
        }
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

    /// @notice The authority's override: it may allow a market that is not curated, and
    ///         may revoke a compromised one even while the vault still holds its base.
    function setMarketAllowed(bytes32 id, address market, bool allowed) external onlyUpgradeAuthority {
        AgentRecord storage a = RegistryStorage.layout().agents[id];
        if (a.status == Status.None) revert UnknownAgent();
        if (allowed && IMarket(market).quoteToken() != AccessStorage.layout().accountingAsset) {
            revert MarketQuoteMismatch();
        }
        // H2: the vault itself rejects a market whose base has no feed (NoPriceFeed).
        AgentVault(a.vault).setMarketAllowed(market, allowed);
        emit AgentMarketChanged(id, market, allowed);
    }

    /// @notice The creator picks which curated markets their own agent may trade.
    /// @dev Curation stays with the authority because a market is an arbitrary callee
    ///      of `executeSwap`; choosing among vetted ones is a creator decision.
    function setAgentMarket(bytes32 id, address market, bool allowed) external {
        AgentRecord storage a = _ownedAgent(id);
        if (a.status == Status.Revoked) revert AgentAlreadyRevoked();

        if (allowed) {
            if (!_isCurated(market)) revert MarketNotCurated();
        } else if (IERC20(IMarket(market).baseToken()).balanceOf(a.vault) != 0) {
            // heldBases never shrinks and only this market can sell that base back to
            // USDC, so disabling it here would strand the position and block redemptions.
            revert MarketStillHeld();
        }

        AgentVault(a.vault).setMarketAllowed(market, allowed);
        emit AgentMarketChanged(id, market, allowed);
    }

    /* ------------------------------ internal ----------------------------- */

    function _isCurated(address market) internal view returns (bool) {
        address[] storage curated = AccessStorage.layout().curatedMarkets;
        uint256 n = curated.length;
        for (uint256 i = 0; i < n; i++) {
            if (curated[i] == market) return true;
        }
        return false;
    }

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

    /// @notice The creator's latest NanSigil attestation, bound here by looking up the
    ///         agent's creator wallet. `timestamp == 0` means none (or NanSigil unset).
    ///         Plaintext for `INanSigil.verify` comes from NanSigil's event / an indexer.
    function agentAttestation(bytes32 id) external view returns (bytes32 attestHash, uint64 timestamp) {
        address nansigil = AccessStorage.layout().nansigil;
        AgentRecord storage a = RegistryStorage.layout().agents[id];
        if (nansigil == address(0) || a.status == Status.None) return (bytes32(0), 0);
        return INanSigil(nansigil).latest(a.creator);
    }
}
