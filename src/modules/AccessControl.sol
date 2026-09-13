// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// OpenZeppelin v5.7 menyatukan varian upgradeable ke paket utama: Initializable dan
// UUPSUpgradeable memakai ERC-7201, dan ReentrancyGuard kini stateless-untuk-proxy —
// slot-nya ber-namespace dan nilai nol dibaca sebagai "tidak sedang masuk", sehingga
// konstruktor yang tidak pernah berjalan di proxy tidak jadi masalah.
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {AccessLayout, AccessStorage} from "../storage/AccessStorage.sol";
import {Agent, Status} from "../Types.sol";
import {AgentLayout, AgentStorage} from "../storage/AgentStorage.sol";
import {AgentNotActive, NotAuroraReceiver, NotUpgradeAuthority, Paused, ZeroAddress} from "../Errors.sol";
import {AuroraReceiverChanged, KuruChanged, PausedChanged} from "../Events.sol";

/// @notice Otorisasi, konfigurasi, dan jalur upgrade.
///
/// @dev Aturan keras seluruh sistem, ditegakkan di sini dan diwarisi modul lain:
///      **identitas tidak pernah datang dari calldata.** Tidak ada fungsi `external`
///      yang menerima `address owner`. Owner diturunkan dari `msg.sender` — yang
///      `delegatecall` pertahankan apa adanya dari EOA — atau, untuk aksi agent,
///      dari registry lewat `_resolveActor`. Satu pelanggaran saja setara confused
///      deputy dan seluruh vault bisa dikuras.
///
///      Pengecualian tunggal: `VaultModule.creditDeposit`, yang menerima `owner`
///      tetapi hanya bisa dipanggil Aurora Receiver ber-allowlist.
abstract contract AccessControl is Initializable, ReentrancyGuard, UUPSUpgradeable {
    modifier onlyUpgradeAuthority() {
        if (msg.sender != AccessStorage.layout().upgradeAuthority) revert NotUpgradeAuthority();
        _;
    }

    modifier onlyAuroraReceiver() {
        if (msg.sender != AccessStorage.layout().auroraReceiver) revert NotAuroraReceiver();
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
        // Aset akuntansi dikunci saat inisialisasi dan tidak punya setter. Mengubahnya
        // setelah ada dana akan mendenominasi ulang setiap allowance dan setiap angka
        // `totalDelegated` secara diam-diam — invarian I3 langsung tidak bermakna.
        $.accountingAsset = accountingAsset_;
    }

    /* ------------------------------- admin ------------------------------- */

    function setAuroraReceiver(address receiver) external onlyUpgradeAuthority {
        AccessLayout storage $ = AccessStorage.layout();
        emit AuroraReceiverChanged($.auroraReceiver, receiver);
        $.auroraReceiver = receiver;
    }

    function setKuru(address kuru_) external onlyUpgradeAuthority {
        AccessLayout storage $ = AccessStorage.layout();
        emit KuruChanged($.kuru, kuru_);
        $.kuru = kuru_;
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

    function kuru() external view returns (address) {
        return AccessStorage.layout().kuru;
    }

    function accountingAsset() external view returns (address) {
        return AccessStorage.layout().accountingAsset;
    }

    function paused() external view returns (bool) {
        return AccessStorage.layout().paused;
    }

    /* ------------------------------ internal ----------------------------- */

    /// @notice Menerjemahkan `msg.sender` menjadi pemilik dana yang bertanggung jawab.
    /// @dev Inilah satu-satunya tempat identitas trading ditentukan. Wallet yang tidak
    ///      terdaftar dianggap owner yang bertindak untuk dirinya sendiri; wallet yang
    ///      terdaftar hanya bisa bertindak untuk owner yang mendaftarkannya, tidak
    ///      pernah untuk owner lain, karena `owner` diambil dari record — bukan argumen.
    /// @return owner Pemilik dana yang saldonya akan bergerak.
    /// @return agentId 0 bila owner bertindak langsung.
    function _resolveActor() internal view returns (address owner, bytes32 agentId) {
        AgentLayout storage $ = AgentStorage.layout();
        bytes32 id = $.idOfWallet[msg.sender];
        if (id == bytes32(0)) return (msg.sender, bytes32(0));

        Agent storage a = $.agents[id];
        if (a.status != Status.Active) revert AgentNotActive();
        return (a.owner, id);
    }

    function _authorizeUpgrade(address) internal override onlyUpgradeAuthority {}
}
