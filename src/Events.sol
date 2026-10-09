// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Status} from "./Types.sol";

/* ----------------------------- CustosCore: admin -------------------------- */

event MarketAdapterChanged(address indexed oldAdapter, address indexed newAdapter);

event AgentMarketChanged(bytes32 indexed agentId, address indexed market, bool allowed);

event CuratedMarketChanged(address indexed market, bool curated);

event PausedChanged(bool paused);

event MinSeedChanged(uint128 oldMinSeed, uint128 newMinSeed);

event UpgradeAuthorityChanged(address indexed oldAuthority, address indexed newAuthority);

event YieldSourceAllowedChanged(address indexed yieldSource, bool allowed);

event PriceOracleChanged(address indexed oldOracle, address indexed newOracle);

event VaultFactoryChanged(address indexed oldFactory, address indexed newFactory);

event NanSigilChanged(address indexed oldNanSigil, address indexed newNanSigil);

event FeedChanged(address indexed token, address indexed aggregator, uint32 maxStaleness);

/* ----------------------------- CustosCore: agent --------------------------- */

/// @dev `description` lives only in the log; on-chain stores just its hash (D9).
event AgentRegistered(
    bytes32 indexed id,
    address indexed creator,
    address indexed wallet,
    address vault,
    bytes32 name,
    string description,
    uint128 allowance,
    uint32 periodLength,
    uint16 feeRate,
    bool isPublic
);

event AgentStatusChanged(bytes32 indexed id, Status oldStatus, Status newStatus);

event AgentAllowanceChanged(bytes32 indexed id, uint128 oldAllowance, uint128 newAllowance);

event AgentPeriodChanged(bytes32 indexed id, uint32 oldPeriodLength, uint32 newPeriodLength);

event AgentPublicChanged(bytes32 indexed id, bool isPublic);

/* ------------------------------- AgentVault -------------------------------- */

/// @dev `newSharePrice` scaled 1e18 — indexer gets a chart data point for free.
event SwapExecuted(
    address indexed vault,
    bytes32 indexed agentId,
    address indexed market,
    bool isBuy,
    uint128 baseAmount,
    uint128 quoteAmount,
    uint128 notionalCharged,
    uint256 newTotalAssets,
    uint256 newSharePrice
);

event AgentPeriodRolled(bytes32 indexed agentId, uint64 newPeriodStart, uint128 usedBefore);

event FeeMinted(
    address indexed vault,
    address indexed creator,
    uint256 feeShares,
    uint256 feeAssets,
    uint256 newHighWaterMark
);

event SubscriberDeposited(address indexed vault, address indexed subscriber, uint256 assets, uint256 shares);

event SubscriberRedeemed(address indexed vault, address indexed subscriber, uint256 assets, uint256 shares);

event SeedDeposited(
    address indexed vault, address indexed creator, uint256 assets, uint256 shares, address deadAddress
);

event CircuitBreakerTriggered(
    address indexed vault, uint256 currentSharePrice, uint256 highWaterMark, uint16 maxDrawdownBps
);

event YieldPushed(address indexed vault, uint256 amount);

event YieldPulled(address indexed vault, uint256 amount);
