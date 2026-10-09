// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeploymentFile} from "./DeploymentFile.sol";
import {CustosCore} from "../src/CustosCore.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";

/// @notice `make init` — konfigurasi pasca-deploy oleh upgradeAuthority. Idempotent:
///         semua setter menimpa, jadi aman dijalankan ulang setelah ganti feed,
///         market, atau yield source. Urutan wajib sebelum `registerAgent`:
///         vaultFactory → priceOracle → market adapter + kurasi market →
///         yieldSource allowlist → feed MON/USD.
contract InitScript is DeploymentFile {
    function run() external {
        uint256 authorityKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        CustosCore custos = CustosCore(_must("CUSTOS_PROXY", "custosProxy"));
        PriceOracle oracle = PriceOracle(_must("PRICE_ORACLE", "priceOracle"));
        address vaultFactory = _must("VAULT_FACTORY", "vaultFactory");
        address nansigil = _addr("NANSIGIL_ADDRESS", "nansigil");
        address market = _must("MARKET_ADDRESS", "market");
        address mon = _must("MON_ADDRESS", "mon");
        address monUsdFeed = _must("MON_USD_FEED", "monUsdFeed");
        address yieldSource = _addr("YIELD_SOURCE", "yieldSource");
        uint32 maxStaleness = uint32(vm.envOr("FEED_MAX_STALENESS", uint256(1 days)));
        uint128 minSeed = uint128(vm.envOr("MIN_SEED_USDC", uint256(500)) * 1e6);

        vm.startBroadcast(authorityKey);

        custos.setVaultFactory(vaultFactory);
        if (nansigil != address(0)) custos.setNanSigil(nansigil);
        custos.setPriceOracle(address(oracle));
        custos.setMarketAdapter(market);
        // A vault allows no market on its own, and registerAgent only accepts curated
        // ones, so without this every new agent starts unable to trade. Guarded because
        // setCuratedMarket reverts on a duplicate and this script must stay re-runnable.
        if (!_isCurated(custos, market)) custos.setCuratedMarket(market, true);
        custos.setMinSeed(minSeed);
        if (yieldSource != address(0)) custos.setYieldSourceAllowed(yieldSource, true);
        oracle.setFeed(mon, AggregatorV3Interface(monUsdFeed), maxStaleness);

        vm.stopBroadcast();

        _put("monUsdFeed", monUsdFeed);
    }

    function _isCurated(CustosCore custos, address market) internal view returns (bool) {
        address[] memory curated = custos.curatedMarkets();
        for (uint256 i = 0; i < curated.length; i++) {
            if (curated[i] == market) return true;
        }
        return false;
    }
}
