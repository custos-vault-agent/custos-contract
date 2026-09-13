// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ------------------------------- akses ---------------------------------- */

error NotUpgradeAuthority();
error NotAuroraReceiver();
error Paused();
error ZeroAddress();

/* ------------------------------- agent ---------------------------------- */

error NotCreator();
/// @dev Ikatan wallet→agent permanen (D8); wallet ini sudah pernah dipakai.
error WalletAlreadyBound();
error UnknownAgent();
error AgentAlreadyRevoked();
/// @dev Creator tidak boleh mendaftarkan wallet-nya sendiri sebagai agent.
error SelfDelegation();
error FeeRateOutOfRange();
error DrawdownOutOfRange();
error UtilizationOutOfRange();
error SeedTooSmall();

/* ------------------------------- nansen ---------------------------------- */

error NotAttestor();
error AttestationInvalid();
error AttestationHashMismatch();

/* ------------------------------- vault ----------------------------------- */

error OnlyAgent();
error OnlyCustosCore();
error VaultNotActive();
error VaultPausedOrRevoked();
error AllowanceExceeded(uint256 headroom);
error MarketNotAllowed();
error MarketQuoteMismatch();
error SlippageExceeded();
error ZeroAmount();
/// @dev Agent memanggil deposit/redeem/withdraw/mint/transfer/approve pada share token.
error AgentCannotCallThis();
/// @dev Yield source gagal mengembalikan dana saat `_pullFromYield`.
error YieldWithdrawFailed();
