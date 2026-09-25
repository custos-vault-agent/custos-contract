// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeploymentFile} from "./DeploymentFile.sol";
import {KuruMarketAdapter} from "../src/adapters/KuruMarketAdapter.sol";
import {MockYieldSource} from "../src/adapters/MockYieldSource.sol";
import {IKuruRouter} from "../src/interfaces/IKuruRouter.sol";
import {MockAggregator} from "../test/mocks/MockAggregator.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockKuruFactory} from "../test/mocks/MockKuruFactory.sol";
import {MockKuruRouter} from "../test/mocks/MockKuruRouter.sol";

/// @notice `make deployMock` — semua dependensi eksternal versi palsu: token,
///         pasar Kuru, yield source, dan feed MON/USD. Untuk anvil, atau testnet
///         yang belum punya salah satunya. Tidak menyentuh CustosCore.
contract DeployMockScript is DeploymentFile {
    uint256 internal constant USDC = 1e6;
    uint256 internal constant MON = 1e18;

    function run() external {
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 mon = new MockERC20("Monad", "MON", 18);

        MockKuruFactory kuruFactory = new MockKuruFactory();
        MockKuruRouter kuruRouter = new MockKuruRouter();
        address orderbook = kuruFactory.deployProxy(
            0, address(mon), address(usdc), 1e10, 1e2, 1, 1e6, type(uint96).max, 30, 10, 0
        );
        KuruMarketAdapter market =
            new KuruMarketAdapter(IKuruRouter(address(kuruRouter)), orderbook, address(0));
        kuruRouter.setPrice(orderbook, 2 * USDC, 1 * MON); // 1 MON = 2 USDC
        mon.mint(address(kuruRouter), 1_000_000 * MON);
        usdc.mint(address(kuruRouter), 1_000_000 * USDC);

        MockYieldSource yieldSource = new MockYieldSource(address(usdc), 500); // 5% APY
        MockAggregator monUsdFeed = new MockAggregator(8, 2e8); // harga sama dengan router

        vm.stopBroadcast();

        _put("usdc", address(usdc));
        _put("mon", address(mon));
        _put("kuruFactory", address(kuruFactory));
        _put("kuruRouter", address(kuruRouter));
        _put("kuruOrderbook", orderbook);
        _put("market", address(market));
        _put("yieldSource", address(yieldSource));
        _put("monUsdFeed", address(monUsdFeed));
    }
}
