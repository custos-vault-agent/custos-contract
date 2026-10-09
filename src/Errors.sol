// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ------------------------------- access --------------------------------- */

error NotUpgradeAuthority();
error Paused();
error ZeroAddress();

/* ------------------------------- agent ---------------------------------- */

error NotCreator();
/// @dev Wallet→agent binding is permanent (D8); this wallet was already used.
error WalletAlreadyBound();
error UnknownAgent();
error AgentAlreadyRevoked();
/// @dev A creator cannot register their own wallet as the agent.
error SelfDelegation();
error FeeRateOutOfRange();
error DrawdownOutOfRange();
error UtilizationOutOfRange();
error SeedTooSmall();
/// @dev H1: yield source must be protocol-allowlisted.
error YieldSourceNotAllowed();

/* ------------------------------- vault ----------------------------------- */

error OnlyAgent();
error OnlyCustosCore();
error VaultNotActive();
error VaultPausedOrRevoked();
error AllowanceExceeded(uint256 headroom);
error MarketNotAllowed();
error MarketQuoteMismatch();
error TooManyCuratedMarkets();
error MarketAlreadyCurated();
error MarketNotCurated();
error MarketStillHeld();
error SeedLocked();
error SeedExceeded();
error AgentNotRevoked();
error BaseStillHeld();
/// @dev H2: the market's base token has no feed in PriceOracle.
error NoPriceFeed();
error OracleQuoteMismatch();
error SlippageExceeded();
/// @dev M1: one swap moved the share price down by more than maxDrawdownBps.
error SwapDrawdownExceeded();
error ZeroAmount();
/// @dev The agent called deposit/redeem/withdraw/mint/transfer/approve on the share token.
error AgentCannotCallThis();
/// @dev Yield source returned nothing in `_pullFromYield`.
error YieldWithdrawFailed();

/* ------------------------------- oracle ---------------------------------- */

error FeedInvalid();
error StalePrice();
