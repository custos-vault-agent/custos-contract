// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {AccessLayout, AccessStorage} from "../storage/AccessStorage.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {
    NotAuroraReceiver,
    NotUpgradeAuthority,
    OracleQuoteMismatch,
    Paused,
    ZeroAddress
} from "../Errors.sol";
import {
    AuroraReceiverChanged,
    MarketAdapterChanged,
    MinSeedChanged,
    NanSigilChanged,
    PausedChanged,
    PriceOracleChanged,
    UpgradeAuthorityChanged,
    VaultFactoryChanged,
    YieldSourceAllowedChanged
} from "../Events.sol";

/// @notice Authorization, configuration, and the upgrade path.
///
/// @dev System-wide rule: **identity never comes from calldata.** The one exception
///      is `creditDeposit`, where the allowlisted Aurora Receiver names the subscriber.
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
        // No setter: changing the accounting asset after vaults exist would silently
        // redenominate every allowance and share price.
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

    /// @dev H2: frozen into every vault created afterwards. Must be denominated in the
    ///      accounting asset or vault `totalAssets` would be in the wrong unit.
    function setPriceOracle(address oracle) external onlyUpgradeAuthority {
        AccessLayout storage $ = AccessStorage.layout();
        if (IPriceOracle(oracle).quoteToken() != $.accountingAsset) revert OracleQuoteMismatch();
        emit PriceOracleChanged($.priceOracle, oracle);
        $.priceOracle = oracle;
    }

    /// @dev A new factory means a new AgentVault version for vaults created afterwards.
    function setVaultFactory(address factory) external onlyUpgradeAuthority {
        AccessLayout storage $ = AccessStorage.layout();
        emit VaultFactoryChanged($.vaultFactory, factory);
        $.vaultFactory = factory;
    }

    /// @dev Where `agentAttestation` looks up the creator's reputation. address(0) disables it.
    function setNanSigil(address nansigil_) external onlyUpgradeAuthority {
        AccessLayout storage $ = AccessStorage.layout();
        emit NanSigilChanged($.nansigil, nansigil_);
        $.nansigil = nansigil_;
    }

    /// @dev H1: a yield source holds subscriber funds, so it is protocol-gated like markets.
    function setYieldSourceAllowed(address yieldSource, bool allowed) external onlyUpgradeAuthority {
        AccessStorage.layout().allowedYieldSources[yieldSource] = allowed;
        emit YieldSourceAllowedChanged(yieldSource, allowed);
    }

    function pause() external onlyUpgradeAuthority {
        AccessStorage.layout().paused = true;
        emit PausedChanged(true);
    }

    /// @dev L7: rotating the multisig no longer needs an implementation upgrade.
    function transferUpgradeAuthority(address newAuthority) external onlyUpgradeAuthority {
        if (newAuthority == address(0)) revert ZeroAddress();
        AccessLayout storage $ = AccessStorage.layout();
        emit UpgradeAuthorityChanged($.upgradeAuthority, newAuthority);
        $.upgradeAuthority = newAuthority;
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

    function priceOracle() external view returns (address) {
        return AccessStorage.layout().priceOracle;
    }

    function vaultFactory() external view returns (address) {
        return AccessStorage.layout().vaultFactory;
    }

    function nansigil() external view returns (address) {
        return AccessStorage.layout().nansigil;
    }

    function isYieldSourceAllowed(address yieldSource) external view returns (bool) {
        return AccessStorage.layout().allowedYieldSources[yieldSource];
    }

    function paused() external view returns (bool) {
        return AccessStorage.layout().paused;
    }

    /* ------------------------------ internal ----------------------------- */

    function _authorizeUpgrade(address) internal override onlyUpgradeAuthority {}
}
