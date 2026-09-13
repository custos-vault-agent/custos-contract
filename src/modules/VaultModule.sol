// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Accounting} from "./Accounting.sol";
import {AccessStorage} from "../storage/AccessStorage.sol";
import {VaultLayout, VaultStorage} from "../storage/VaultStorage.sol";
import {Deposited, Withdrawn} from "../Events.sol";
import {ExceedsAvailable, NothingDeposited, ZeroAddress, ZeroAmount} from "../Errors.sol";

/// @notice Kustodi dana. Custos memegang token; `balance` adalah buku besarnya.
abstract contract VaultModule is Accounting {
    using SafeERC20 for IERC20;

    /// @notice Mengkreditkan token yang sudah masuk ke kontrak ini atas nama `owner`.
    ///
    /// @dev Satu-satunya fungsi yang menerima `owner` dari calldata, dan hanya Aurora
    ///      Receiver ber-allowlist yang boleh memanggilnya — dialah yang tahu siapa
    ///      pemilik dana di sisi rantai asal.
    ///
    ///      Tidak ada parameter `amount`. Jumlahnya diukur sebagai selisih antara saldo
    ///      token kontrak dan `totalTracked`, jadi pemanggil tidak bisa mengklaim lebih
    ///      dari yang benar-benar ia kirim. Konsekuensinya transfer dan kredit harus
    ///      berada dalam satu transaksi: siapa pun yang mengkredit lebih dulu akan
    ///      mengambil dana orang lain yang menganggur di kontrak.
    ///
    ///      Token fee-on-transfer ikut tertangani dengan sendirinya — yang tercatat
    ///      adalah yang benar-benar diterima, bukan yang dikirim.
    function creditDeposit(address owner, address token)
        external
        onlyAuroraReceiver
        whenNotPaused
        returns (uint256 amount)
    {
        if (owner == address(0)) revert ZeroAddress();

        VaultLayout storage $ = VaultStorage.layout();
        uint256 tracked = $.totalTracked[token];
        uint256 actual = IERC20(token).balanceOf(address(this));
        if (actual <= tracked) revert NothingDeposited();

        amount = actual - tracked;
        $.balance[owner][token] += amount;
        $.totalTracked[token] = actual;

        emit Deposited(owner, token, amount);
    }

    /// @notice Menarik token ke wallet pemanggil.
    /// @dev Owner selalu `msg.sender`; tidak ada jalur bagi agent untuk menarik dana.
    ///      Sebuah agent yang dikompromikan bisa merugikan lewat trading yang buruk,
    ///      tapi tidak pernah bisa memindahkan dana keluar dari Custos.
    function withdraw(address token, uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        VaultLayout storage $ = VaultStorage.layout();
        uint256 bal = $.balance[msg.sender][token];

        // Batas delegasi hanya berlaku untuk aset akuntansi, karena delegasi
        // didenominasi di dalamnya (D4). Aset lain bebas ditarik penuh.
        uint256 cap = token == AccessStorage.layout().accountingAsset
            ? _availableOf(msg.sender)
            : bal;
        if (amount > cap) revert ExceedsAvailable(cap);

        // Effects sebelum interactions; `nonReentrant` adalah lapis kedua, bukan yang utama.
        $.balance[msg.sender][token] = bal - amount;
        $.totalTracked[token] -= amount;

        emit Withdrawn(msg.sender, token, amount);
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    /* ------------------------------ views -------------------------------- */

    function balanceOf(address owner, address token) external view returns (uint256) {
        return VaultStorage.layout().balance[owner][token];
    }

    function totalTracked(address token) external view returns (uint256) {
        return VaultStorage.layout().totalTracked[token];
    }
}
