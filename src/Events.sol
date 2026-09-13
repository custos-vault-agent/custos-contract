// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Status} from "./Types.sol";

/* ------------------------------- admin ---------------------------------- */

event AuroraReceiverChanged(address indexed oldReceiver, address indexed newReceiver);

event KuruChanged(address indexed oldKuru, address indexed newKuru);

event MarketAllowedChanged(address indexed market, bool allowed);

event PausedChanged(bool paused);

/* ------------------------------- agent ---------------------------------- */

/// @dev `description` hanya hidup di log. On-chain yang tersimpan cuma hash-nya (D9),
///      jadi indexer bisa memverifikasi teks yang ia tampilkan benar-benar milik agent ini.
event AgentRegistered(
    bytes32 indexed id,
    address indexed owner,
    address indexed wallet,
    bytes32 name,
    string description,
    uint128 allowance,
    uint32 periodLength
);

event AgentAllowanceChanged(bytes32 indexed id, uint128 oldAllowance, uint128 newAllowance);

event AgentPeriodChanged(bytes32 indexed id, uint32 oldPeriodLength, uint32 newPeriodLength);

event AgentStatusChanged(bytes32 indexed id, Status oldStatus, Status newStatus);

/// @dev Roll-over periode bersifat malas — terjadi saat trade pertama setelah periode
///      lewat, bukan pada detik pergantiannya. Event ini yang membuat indexer bisa
///      merekonstruksi pemakaian per periode tanpa menebak.
event AgentPeriodRolled(bytes32 indexed id, uint64 newPeriodStart, uint128 usedBefore);

/* ------------------------------- vault ---------------------------------- */

event Deposited(address indexed owner, address indexed token, uint256 amount);

event Withdrawn(address indexed owner, address indexed token, uint256 amount);

/* ------------------------------ trading --------------------------------- */

/// @dev `agentId` bernilai 0 kalau owner yang bertindak langsung.
event SwapExecuted(
    address indexed owner,
    bytes32 indexed agentId,
    address indexed market,
    bool isBuy,
    uint128 baseAmount,
    uint128 quoteAmount,
    uint128 notionalCharged
);
