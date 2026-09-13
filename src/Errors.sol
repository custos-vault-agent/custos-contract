// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ------------------------------- akses ---------------------------------- */

error NotUpgradeAuthority();
error NotAuroraReceiver();
error Paused();
error ZeroAddress();

/* ------------------------------- agent ---------------------------------- */

/// @dev Wallet terdaftar tapi statusnya bukan Active (Paused / Revoked).
error AgentNotActive();
error NotAgentOwner();
/// @dev Ikatan wallet→agent permanen (D8); wallet ini sudah pernah dipakai.
error WalletAlreadyBound();
error UnknownAgent();
error AgentAlreadyRevoked();
error TooManyAgents();
/// @dev Owner tidak boleh mendaftarkan wallet-nya sendiri sebagai agent: itu
///      membuat `_resolveActor` ambigu dan mengunci owner di balik allowance-nya.
error SelfDelegation();

/* ----------------------------- allowance -------------------------------- */

error AllowanceExceeded(uint256 headroom);
/// @dev Saldo bebas owner tidak cukup untuk menaikkan delegasi sebesar ini.
error InsufficientAvailable(uint256 available);

/* ------------------------------- vault ---------------------------------- */

error ExceedsAvailable(uint256 cap);
error NothingDeposited();
error ZeroAmount();

/* ------------------------------ trading --------------------------------- */

error MarketNotAllowed();
error MarketQuoteMismatch();
error InsufficientBalance(uint256 balance);
error PriceTooHigh();
error SlippageExceeded();
