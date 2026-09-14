// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AccessControl} from "./AccessControl.sol";
import {VaultFactory} from "./VaultFactory.sol";
import {AccessLayout, AccessStorage} from "../storage/AccessStorage.sol";
import {AgentRecord, Status} from "../Types.sol";
import {RegistryLayout, RegistryStorage} from "../storage/RegistryStorage.sol";
import {AgentVault} from "../AgentVault.sol";
import {IMarket} from "../interfaces/IMarket.sol";
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

/// @notice Registry agent. Menggantikan `AgentCore` v0.1 — metadata agent hidup di
///         sini, tapi dana dan trading hidup di `AgentVault` masing-masing.
///
/// @dev Setiap fungsi di sini ditandatangani creator, tidak pernah oleh agent.
abstract contract AgentRegistry is AccessControl, VaultFactory {
    using SafeERC20 for IERC20;

    /// @param yieldSource `address(0)` menonaktifkan idle yield untuk vault ini (D22).
    /// @param seedAmount Wajib `>= minSeed` (D15); locked permanen di `address(1)`.
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
    ) external whenNotPaused returns (bytes32 id, address vault) {
        if (wallet == address(0)) revert ZeroAddress();
        // Wallet creator sendiri sebagai agent akan membuat vault-nya sendiri
        // memblokir dirinya lewat `onlyAgent` — creator tidak akan pernah bisa
        // mengelola vault-nya sendiri sebagai subscriber biasa.
        if (wallet == msg.sender) revert SelfDelegation();
        if (feeRate > 5000) revert FeeRateOutOfRange();
        if (maxDrawdownBps > 5000) revert DrawdownOutOfRange();
        if (maxUtilizationBps < 1000 || maxUtilizationBps > 9500) revert UtilizationOutOfRange();

        AccessLayout storage access = AccessStorage.layout();
        if (seedAmount < access.minSeed) revert SeedTooSmall();

        RegistryLayout storage $ = RegistryStorage.layout();
        // Ikatan permanen (D8): wallet yang pernah dipakai tidak bisa didaftarkan lagi.
        if ($.idOfWallet[wallet] != bytes32(0)) revert WalletAlreadyBound();

        id = keccak256(abi.encode(msg.sender, wallet));

        vault = _deployVault(
            id,
            msg.sender,
            wallet,
            access.accountingAsset,
            access.marketAdapter,
            yieldSource,
            feeRate,
            maxDrawdownBps,
            maxUtilizationBps,
            allowance,
            periodLength,
            name
        );

        // Transfer dulu, baru minta vault mencatatnya — pola yang sama dengan
        // v0.1's `creditDeposit`: vault mengukur selisih, tidak mempercayai klaim.
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
            registeredAt: uint64(block.timestamp),
            nansenAttestHash: bytes32(0),
            nansenSignature: ""
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

    /// @notice Mencabut agent secara permanen. Record tidak pernah dihapus — direktori
    ///         publik bersifat append-only dan ikatan wallet tetap dipertahankan.
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

    /// @notice D16: hanya mempengaruhi visibilitas di marketplace. On-chain tetap
    ///         permissionless — `deposit` di vault tidak pernah dijaga `isPublic`.
    function setPublic(bytes32 id, bool isPublic) external {
        AgentRecord storage a = _ownedAgent(id);
        a.isPublic = isPublic;
        emit AgentPublicChanged(id, isPublic);
    }

    /// @notice Mengizinkan atau melarang sebuah pasar untuk satu vault. Tetap
    ///         protocol-gated seperti v0.1 — D4 (quote harus USDC) adalah invarian
    ///         keamanan seluruh model allowance/reserve-ratio, bukan pilihan creator.
    function setMarketAllowed(bytes32 id, address market, bool allowed) external onlyUpgradeAuthority {
        if (allowed && IMarket(market).quoteToken() != AccessStorage.layout().accountingAsset) {
            revert MarketQuoteMismatch();
        }
        AgentRecord storage a = RegistryStorage.layout().agents[id];
        if (a.status == Status.None) revert UnknownAgent();
        AgentVault(a.vault).setMarketAllowed(market, allowed);
        emit MarketAllowedChanged(market, allowed);
    }

    /// @notice Menerima kredit deposit lintas-chain dari Aurora Receiver, dan
    ///         meneruskannya sebagai deposit ERC-4626 biasa ke vault tujuan.
    /// @dev Batas kepercayaan sama seperti v0.1's `creditDeposit`: Aurora Receiver
    ///      adalah satu-satunya pemanggil yang dipercaya tahu identitas dan jumlah
    ///      yang benar dari sisi rantai asal (spec v1 §11 O1). Dananya sendiri
    ///      ditarik dari Aurora Receiver ke sini dulu, baru diteruskan lewat
    ///      `deposit()` biasa — tidak ada fungsi baru di AgentVault untuk ini.
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

    /// @dev D19: revoke permanen — begitu status Revoked, tidak ada transisi lain
    ///      yang boleh lewat, termasuk pause/resume/revoke ulang.
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
