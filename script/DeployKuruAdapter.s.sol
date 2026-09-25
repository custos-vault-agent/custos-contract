// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";

import {DeploymentFile} from "./DeploymentFile.sol";
import {KuruMarketAdapter} from "../src/adapters/KuruMarketAdapter.sol";
import {IKuruOrderBook} from "../src/interfaces/IKuruOrderBook.sol";
import {IKuruRouter} from "../src/interfaces/IKuruRouter.sol";

/// @notice `make deployKuruAdapter` — one `KuruMarketAdapter` for one real Kuru
///         orderbook. `make deployMock` covers the same job with a fake router,
///         so this script is what a testnet or mainnet deployment uses instead.
///
/// @dev The adapter reads the base and the quote token from the orderbook once,
///      in its constructor, and then freezes them. This script prints both and
///      fails early if the quote is not the accounting asset, because the whole
///      allowance model reads notional in that asset (D4).
contract DeployKuruAdapterScript is DeploymentFile {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address router = _must("KURU_ROUTER", "kuruRouter");
        address orderbook = _must("KURU_ORDERBOOK", "kuruOrderbook");
        address usdc = _must("USDC_ADDRESS", "usdc");

        (,, address base,, address quote,,,,,,) = IKuruOrderBook(orderbook).getMarketParams();
        console2.log("orderbook base ", base);
        console2.log("orderbook quote", quote);
        // Kuru reports the native token as address(0). Custos moves ERC-20 only:
        // the adapter approves and transfers, the vault measures balance deltas, and
        // PriceOracle reads decimals(). Pick a market whose base is a contract.
        require(base != address(0), "base is the native token, not an ERC-20 market");
        require(quote == usdc, "quote is not the accounting asset");

        vm.startBroadcast(deployerKey);
        KuruMarketAdapter adapter = new KuruMarketAdapter(IKuruRouter(router), orderbook);
        vm.stopBroadcast();

        _put("kuruRouter", router);
        _put("kuruOrderbook", orderbook);
        _put("market", address(adapter));
        // `make init` reads `.market` and `.mon`; the base token is the one this
        // market trades, so a PriceOracle feed is needed for it.
        _put("mon", base);

        console2.log("KuruMarketAdapter", address(adapter));
    }
}
