// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {AccessLayout, AccessStorage} from "../storage/AccessStorage.sol";
import {NotAttestor, NotAuroraReceiver, NotUpgradeAuthority, Paused, ZeroAddress} from "../Errors.sol";
import {AttestorChanged, AuroraReceiverChanged, MarketAdapterChanged, MinSeedChanged, PausedChanged} from
    "../Events.sol";

/// @notice Otorisasi, konfigurasi, dan jalur upgrade.
///
/// @dev Aturan keras seluruh sistem: **identitas tidak pernah datang dari calldata.**
///      Satu-satunya pengecualian sekarang ada di dua tempat, bukan satu: CustosCore
///      `creditDeposit` (Aurora Receiver ber-allowlist) dan AgentVault
///      `processDeposit` (hanya bisa dipanggil CustosCore, yang sendiri sudah
///      memverifikasi pemanggilnya adalah Aurora Receiver).
///
///      `_resolveActor` v0.1 dihapus tanpa pengganti: trading sekarang terjadi di
///      AgentVault, yang mengenali agent-nya lewat immutable `agent` — tidak ada lagi
///      "wallet terdaftar bertindak untuk owner" yang perlu diselesaikan di CustosCore.
abstract contract AccessControl is Initializable, ReentrancyGuard, UUPSUpgradeable {
    modifier onlyUpgradeAuthority() {
        if (msg.sender != AccessStorage.layout().upgradeAuthority) revert NotUpgradeAuthority();
        _;
    }

    modifier onlyAuroraReceiver() {
        if (msg.sender != AccessStorage.layout().auroraReceiver) revert NotAuroraReceiver();
        _;
    }

    modifier onlyAttestor() {
        if (msg.sender != AccessStorage.layout().attestor) revert NotAttestor();
        _;
    }

    modifier whenNotPaused() {
        if (AccessStorage.layout().paused) revert Paused();
        _;
    }

    /* --------------------------- initialization -------------------------- */

    function __AccessControl_init(address upgradeAuthority_, address accountingAsset_)
        internal
        onlyInitializing
    {
        if (upgradeAuthority_ == address(0) || accountingAsset_ == address(0)) revert ZeroAddress();
        AccessLayout storage $ = AccessStorage.layout();
        $.upgradeAuthority = upgradeAuthority_;
        // Aset akuntansi dikunci saat inisialisasi dan tidak punya setter — sama
        // seperti v0.1, alasannya tidak berubah: mengubahnya setelah ada vault akan
        // mendenominasi ulang setiap allowance dan setiap share price secara diam-diam.
        $.accountingAsset = accountingAsset_;
    }

    /* ------------------------------- admin ------------------------------- */

    function setAuroraReceiver(address receiver) external onlyUpgradeAuthority {
        AccessLayout storage $ = AccessStorage.layout();
        emit AuroraReceiverChanged($.auroraReceiver, receiver);
        $.auroraReceiver = receiver;
    }

    function setMarketAdapter(address adapter) external onlyUpgradeAuthority {
        AccessLayout storage $ = AccessStorage.layout();
        emit MarketAdapterChanged($.marketAdapter, adapter);
        $.marketAdapter = adapter;
    }

    function setMinSeed(uint128 amount) external onlyUpgradeAuthority {
        AccessLayout storage $ = AccessStorage.layout();
        emit MinSeedChanged($.minSeed, amount);
        $.minSeed = amount;
    }

    function setAttestor(address newAttestor) external onlyUpgradeAuthority {
        if (newAttestor == address(0)) revert ZeroAddress();
        AccessLayout storage $ = AccessStorage.layout();
        emit AttestorChanged($.attestor, newAttestor);
        $.attestor = newAttestor;
    }

    function pause() external onlyUpgradeAuthority {
        AccessStorage.layout().paused = true;
        emit PausedChanged(true);
    }

    function unpause() external onlyUpgradeAuthority {
        AccessStorage.layout().paused = false;
        emit PausedChanged(false);
    }

    /* ------------------------------- views ------------------------------- */

    function upgradeAuthority() external view returns (address) {
        return AccessStorage.layout().upgradeAuthority;
    }

    function auroraReceiver() external view returns (address) {
        return AccessStorage.layout().auroraReceiver;
    }

    function marketAdapter() external view returns (address) {
        return AccessStorage.layout().marketAdapter;
    }

    function accountingAsset() external view returns (address) {
        return AccessStorage.layout().accountingAsset;
    }

    function minSeed() external view returns (uint128) {
        return AccessStorage.layout().minSeed;
    }

    function attestor() external view returns (address) {
        return AccessStorage.layout().attestor;
    }

    function paused() external view returns (bool) {
        return AccessStorage.layout().paused;
    }

    /* ------------------------------ internal ----------------------------- */

    function _authorizeUpgrade(address) internal override onlyUpgradeAuthority {}
}
