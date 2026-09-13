// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Accounting} from "./Accounting.sol";
import {Agent, Status} from "../Types.sol";
import {AgentLayout, AgentStorage} from "../storage/AgentStorage.sol";
import {
    AgentAlreadyRevoked,
    NotAgentOwner,
    SelfDelegation,
    TooManyAgents,
    UnknownAgent,
    WalletAlreadyBound,
    ZeroAddress
} from "../Errors.sol";
import {
    AgentAllowanceChanged,
    AgentPeriodChanged,
    AgentRegistered,
    AgentStatusChanged
} from "../Events.sol";

/// @notice Registry agent. Pendaftaran, batas belanja, dan siklus hidupnya.
///
/// @dev Setiap fungsi di sini ditandatangani Owner Wallet, tidak pernah oleh agent.
///      Agent tidak punya jalur untuk mengubah catatannya sendiri — termasuk
///      menaikkan allowance-nya, melanjutkan dirinya setelah di-pause, atau
///      memindahkan kepemilikan.
abstract contract AgentCore is Accounting {
    /// @notice Mendaftarkan wallet agent baru di bawah kepemilikan pemanggil.
    /// @param description Hanya masuk log; on-chain cuma hash-nya yang tersimpan (D9).
    /// @param periodLength Detik per periode reset; 0 berarti allowance sekali pakai
    ///        yang tidak pernah terisi ulang.
    function registerAgent(
        bytes32 name,
        string calldata description,
        address wallet,
        uint128 allowance,
        uint32 periodLength
    ) external whenNotPaused returns (bytes32 id) {
        if (wallet == address(0)) revert ZeroAddress();
        // Wallet owner sendiri sebagai agent akan membuat `_resolveActor` mengunci
        // owner di balik allowance-nya sendiri — ia jadi tidak bisa berdagang penuh
        // dengan dananya sendiri.
        if (wallet == msg.sender) revert SelfDelegation();

        AgentLayout storage $ = AgentStorage.layout();
        // Ikatan permanen (D8): wallet yang pernah dipakai — bahkan yang sudah
        // dicabut — tidak bisa didaftarkan lagi, oleh siapa pun.
        if ($.idOfWallet[wallet] != bytes32(0)) revert WalletAlreadyBound();
        if ($.agentsOfOwner[msg.sender].length >= MAX_AGENTS_PER_OWNER) revert TooManyAgents();

        id = keccak256(abi.encode(msg.sender, wallet));

        $.agents[id] = Agent({
            name: name,
            wallet: wallet,
            status: Status.Active,
            owner: msg.sender,
            allowance: allowance,
            usedInPeriod: 0,
            reserved: 0,
            periodStart: uint64(block.timestamp),
            periodLength: periodLength,
            descriptionHash: keccak256(bytes(description)),
            registeredAt: uint64(block.timestamp)
        });
        $.idOfWallet[wallet] = id;
        $.agentsOfOwner[msg.sender].push(id);
        $.index.push(id);

        // Delegasi baru harus tertutup saldo yang benar-benar ada. Tanpa ini, allowance
        // hanyalah angka di layar dan janji `available` tidak berarti apa-apa.
        _requireSolvent(msg.sender);

        emit AgentRegistered(id, msg.sender, wallet, name, description, allowance, periodLength);
    }

    /// @notice Mengubah batas belanja agent.
    /// @dev Menurunkan allowance di bawah pemakaian yang sudah berjalan itu sah:
    ///      `remaining` sekadar mendarat di nol. Posisi yang sudah terbuka tidak
    ///      dibatalkan — yang dibatasi adalah belanja baru.
    function setAllowance(bytes32 id, uint128 newAllowance) external whenNotPaused {
        Agent storage a = _ownedAgent(id);

        emit AgentAllowanceChanged(id, a.allowance, newAllowance);
        a.allowance = newAllowance;

        // Diperiksa setelah ditulis: `_delegatedOf` menghitung ulang dari record, jadi
        // yang diuji adalah keadaan yang benar-benar akan berlaku.
        _requireSolvent(a.owner);
    }

    /// @notice Mengubah panjang periode reset.
    /// @dev Periode dimulai ulang dari sekarang, tapi `usedInPeriod` tidak dinolkan:
    ///      kalau ia ikut direset, owner bisa memberi agent kuota tak terbatas hanya
    ///      dengan memanggil fungsi ini berulang kali.
    function setPeriod(bytes32 id, uint32 periodLength) external whenNotPaused {
        Agent storage a = _ownedAgent(id);

        // Roll-over yang tertunda ditulis lebih dulu, supaya kuota periode yang sudah
        // lewat tidak ikut terbawa ke periode baru.
        _rollPeriod(a);

        emit AgentPeriodChanged(id, a.periodLength, periodLength);
        a.periodLength = periodLength;
        a.periodStart = uint64(block.timestamp);

        _requireSolvent(a.owner);
    }

    /// @notice Menghentikan agent sementara. Delegasinya langsung kembali ke `available`.
    function pauseAgent(bytes32 id) external {
        Agent storage a = _ownedAgent(id);
        _setStatus(id, a, Status.Paused);
    }

    /// @notice Mengaktifkan kembali agent yang di-pause.
    /// @dev Owner bisa saja menarik dananya selagi agent tidur, sehingga saldo tidak
    ///      lagi menutupi allowance lama. Dalam kasus itu fungsi ini gagal, bukan
    ///      diam-diam mengecilkan allowance — perubahan batas agent harus selalu
    ///      merupakan keputusan owner yang eksplisit.
    function resumeAgent(bytes32 id) external {
        Agent storage a = _ownedAgent(id);
        _setStatus(id, a, Status.Active);
        _requireSolvent(a.owner);
    }

    /// @notice Mencabut agent secara permanen.
    /// @dev Record-nya tidak pernah dihapus: direktori publik bersifat append-only, dan
    ///      ikatan wallet tetap dipertahankan supaya wallet yang dicabut tidak bisa
    ///      hidup kembali sebagai agent baru.
    function revokeAgent(bytes32 id) external {
        Agent storage a = _ownedAgent(id);
        if (a.status == Status.Revoked) revert AgentAlreadyRevoked();
        _setStatus(id, a, Status.Revoked);
        // Keluar dari daftar agent hidup: loop `_delegatedOf` tetap pendek dan slot
        // kuota owner ikut bebas. Riwayat tetap utuh di `index` dan di event.
        _removeFromOwnerList(a.owner, id);
    }

    /* ------------------------------ internal ----------------------------- */

    function _ownedAgent(bytes32 id) internal view returns (Agent storage a) {
        a = AgentStorage.layout().agents[id];
        if (a.status == Status.None) revert UnknownAgent();
        if (a.owner != msg.sender) revert NotAgentOwner();
    }

    function _setStatus(bytes32 id, Agent storage a, Status next) internal {
        emit AgentStatusChanged(id, a.status, next);
        a.status = next;
    }

    function _removeFromOwnerList(address owner, bytes32 id) internal {
        bytes32[] storage ids = AgentStorage.layout().agentsOfOwner[owner];
        uint256 n = ids.length;
        for (uint256 i = 0; i < n; ++i) {
            if (ids[i] == id) {
                ids[i] = ids[n - 1];
                ids.pop();
                return;
            }
        }
    }

    /* ------------------------------- views ------------------------------- */

    function getAgent(bytes32 id) external view returns (Agent memory) {
        return AgentStorage.layout().agents[id];
    }

    function agentIdOf(address wallet) external view returns (bytes32) {
        return AgentStorage.layout().idOfWallet[wallet];
    }

    /// @notice Agent hidup milik owner. Yang sudah dicabut tidak muncul di sini.
    function agentsOfOwner(address owner) external view returns (bytes32[] memory) {
        return AgentStorage.layout().agentsOfOwner[owner];
    }

    /// @notice Direktori publik, termasuk agent yang sudah dicabut.
    function agentCount() external view returns (uint256) {
        return AgentStorage.layout().index.length;
    }

    function agentAt(uint256 i) external view returns (bytes32) {
        return AgentStorage.layout().index[i];
    }
}
