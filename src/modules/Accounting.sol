// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "./AccessControl.sol";
import {AccessStorage} from "../storage/AccessStorage.sol";
import {Agent, Status} from "../Types.sol";
import {AgentLayout, AgentStorage} from "../storage/AgentStorage.sol";
import {VaultStorage} from "../storage/VaultStorage.sol";
import {InsufficientAvailable} from "../Errors.sol";

/// @notice Matematika delegasi. Satu-satunya sumber definisi `remaining`, `delegated`,
///         dan `available`; modul lain memanggil ke sini alih-alih menghitung sendiri.
///
/// @dev **Delegasi dihitung, bukan disimpan.** Spec awal menyimpan `totalDelegated`
///      sebagai cache per owner. Cache itu tidak bisa dibuat benar: `remaining`
///      berubah sendiri saat sebuah periode lewat — tanpa transaksi apa pun — jadi
///      antara batas periode dan aksi agent berikutnya, cache lebih kecil dari jumlah
///      sebenarnya. Arah salahnya justru yang berbahaya: `available` terlihat lebih
///      besar, owner menarik dana yang seharusnya masih tercadang, dan invarian
///      "saldo ≥ delegasi" jebol tanpa satu pun baris kode yang salah.
///
///      Menghitung ulang dari record agent menghapus seluruh kelas bug itu:
///      roll-over cukup diterapkan di memori saat membaca. Biayanya loop yang
///      dibatasi `MAX_AGENTS_PER_OWNER`, dan hanya agent hidup yang ada di dalamnya.
abstract contract Accounting is AccessControl {
    /// @dev Membatasi loop `_delegatedOf`. Hanya agent hidup yang dihitung — revoke
    ///      membebaskan slot — jadi 32 adalah batas agent aktif serentak, bukan batas
    ///      seumur hidup.
    uint256 internal constant MAX_AGENTS_PER_OWNER = 32;

    /* ---------------------------- periode -------------------------------- */

    /// @notice `usedInPeriod` seperti terlihat sekarang, dengan reset periode yang
    ///         belum sempat ditulis sudah diperhitungkan.
    /// @dev Roll-over bersifat malas di storage tapi harus langsung terlihat di
    ///      pembacaan; kalau tidak, agent tertahan oleh kuota periode yang sudah lewat.
    function _effectiveUsed(Agent storage a) internal view returns (uint128) {
        if (a.periodLength == 0) return a.usedInPeriod; // tanpa reset
        if (block.timestamp < uint256(a.periodStart) + a.periodLength) return a.usedInPeriod;
        return 0;
    }

    /// @notice Menulis roll-over yang tertunda ke storage, bila ada.
    /// @dev Periode maju dalam kelipatan utuh sehingga batasnya tetap di grid tetap —
    ///      bukan bergeser mengikuti waktu trade terakhir.
    /// @return rolled True bila storage berubah, supaya pemanggil bisa emit event.
    /// @return usedBefore Nilai `usedInPeriod` sebelum direset.
    function _rollPeriod(Agent storage a) internal returns (bool rolled, uint128 usedBefore) {
        uint32 len = a.periodLength;
        if (len == 0) return (false, a.usedInPeriod);

        uint256 elapsed = block.timestamp - a.periodStart;
        if (elapsed < len) return (false, a.usedInPeriod);

        usedBefore = a.usedInPeriod;
        // Pembagian sebelum perkalian di sini disengaja: ia membulatkan ke bawah ke
        // kelipatan periode utuh, sehingga batas periode tetap di grid yang sama.
        // forge-lint: disable-next-line(divide-before-multiply)
        a.periodStart = uint64(uint256(a.periodStart) + (elapsed / len) * len);
        a.usedInPeriod = 0;
        return (true, usedBefore);
    }

    /* --------------------------- delegasi -------------------------------- */

    /// @notice Sisa daya beli seorang agent, dalam aset akuntansi.
    /// @dev `reserved` ikut dikurangi karena dana yang tercadang sudah keluar dari
    ///      `balance`; memasukkannya kembali di sini akan menghitungnya dua kali.
    ///      Di MVP nilainya selalu nol (invarian I5).
    function _remaining(Agent storage a) internal view returns (uint256) {
        if (a.status != Status.Active) return 0;
        uint256 spent = uint256(_effectiveUsed(a)) + a.reserved;
        uint256 allowance = a.allowance;
        return spent >= allowance ? 0 : allowance - spent;
    }

    /// @notice Total yang sedang didelegasikan owner ke seluruh agent hidupnya.
    function _delegatedOf(address owner) internal view returns (uint256 total) {
        AgentLayout storage $ = AgentStorage.layout();
        bytes32[] storage ids = $.agentsOfOwner[owner];
        uint256 n = ids.length;
        for (uint256 i = 0; i < n; ++i) {
            total += _remaining($.agents[ids[i]]);
        }
    }

    /// @notice Saldo aset akuntansi yang bebas dipakai atau ditarik owner.
    /// @dev Inilah janji produknya: apa pun yang dilakukan agent, angka ini tidak
    ///      berubah. Trading memindahkan nilai dari `remaining` ke `balance` dan
    ///      sebaliknya dalam jumlah yang sama.
    function _availableOf(address owner) internal view returns (uint256) {
        uint256 bal = VaultStorage.layout().balance[owner][AccessStorage.layout().accountingAsset];
        uint256 delegated = _delegatedOf(owner);
        return bal >= delegated ? bal - delegated : 0;
    }

    /// @notice Menegakkan invarian I3 setelah delegasi owner naik.
    /// @dev Dipanggil setelah perubahan ditulis, bukan sebelum, sehingga pemeriksaan
    ///      selalu terhadap keadaan yang sebenarnya akan berlaku — tidak ada aritmetika
    ///      inkremental yang bisa meleset.
    function _requireSolvent(address owner) internal view {
        uint256 bal = VaultStorage.layout().balance[owner][AccessStorage.layout().accountingAsset];
        uint256 delegated = _delegatedOf(owner);
        if (delegated > bal) revert InsufficientAvailable(bal);
    }

    /* ------------------------------ views -------------------------------- */

    function delegatedOf(address owner) external view returns (uint256) {
        return _delegatedOf(owner);
    }

    function availableOf(address owner) external view returns (uint256) {
        return _availableOf(owner);
    }

    function remainingOf(bytes32 id) external view returns (uint256) {
        return _remaining(AgentStorage.layout().agents[id]);
    }
}
