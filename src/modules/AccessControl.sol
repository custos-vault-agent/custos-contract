// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {AccessLayout, AccessStorage} from "../storage/AccessStorage.sol";
import {IMarket} from "../interfaces/IMarket.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {
    MarketAlreadyCurated,
    MarketQuoteMismatch,
    NotUpgradeAuthority,
    OracleQuoteMismatch,
    Paused,
    TooManyCuratedMarkets,
    ZeroAddress
} from "../Errors.sol";
import {
    CuratedMarketChanged,
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
/// @dev System-wide rule: **identity never comes from calldata.** Cross-chain deposits
///      need no exception: Aurora Intents calls `AgentVault.deposit` from the user's own
///      intermediary account, like any other depositor.
abstract contract AccessControl is Initializable, ReentrancyGuard, UUPSUpgradeable {
    /// @dev Bounds the loop registerAgent runs over the curated list.
    uint256 internal constant MAX_CURATED_MARKETS = 8;

    modifier onlyUpgradeAuthority() {
        if (msg.sender != AccessStorage.layout().upgradeAuthority) revert NotUpgradeAuthority();
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

    function setMarketAdapter(address adapter) external onlyUpgradeAuthority {
        AccessLayout storage $ = AccessStorage.layout();
        emit MarketAdapterChanged($.marketAdapter, adapter);
        $.marketAdapter = adapter;
    }

    /// @notice Markets that every vault is allowed at registration, so a new agent can
    ///         trade without a follow-up transaction. Curation stays protocol-gated: a
    ///         market is an arbitrary callee of `executeSwap`.
    /// @dev The list is capped because `registerAgent` iterates it.
    function setCuratedMarket(address market, bool curated) external onlyUpgradeAuthority {
        AccessLayout storage $ = AccessStorage.layout();
        address[] storage list = $.curatedMarkets;
        uint256 n = list.length;

        if (curated) {
            if (market == address(0)) revert ZeroAddress();
            // D4: the allowance model accounts notionals in the accounting asset.
            if (IMarket(market).quoteToken() != $.accountingAsset) revert MarketQuoteMismatch();
            for (uint256 i = 0; i < n; i++) {
                if (list[i] == market) revert MarketAlreadyCurated();
            }
            if (n >= MAX_CURATED_MARKETS) revert TooManyCuratedMarkets();
            list.push(market);
        } else {
            for (uint256 i = 0; i < n; i++) {
                if (list[i] == market) {
                    list[i] = list[n - 1];
                    list.pop();
                    break;
                }
            }
        }
        emit CuratedMarketChanged(market, curated);
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

    function curatedMarkets() external view returns (address[] memory) {
        return AccessStorage.layout().curatedMarkets;
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
