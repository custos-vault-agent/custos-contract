// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {KuruMarketAdapter} from "../src/adapters/KuruMarketAdapter.sol";
import {IKuruRouter} from "../src/interfaces/IKuruRouter.sol";
import {MockKuruFactory} from "./mocks/MockKuruFactory.sol";
import {MockKuruRouter} from "./mocks/MockKuruRouter.sol";

/// @notice Sisi lain dari `KuruAdapterTest`: bukan orderbook yang sudah ada, tapi
///         market yang baru didaftarkan lewat factory — jalur yang dipakai untuk bawa
///         aset baru ke Kuru (bounty), bukan trading di pasar yang sudah listed.
contract KuruFactoryTest is Base {
    MockKuruFactory internal factory;
    MockKuruRouter internal router;

    function setUp() public override {
        super.setUp();
        factory = new MockKuruFactory();
        router = new MockKuruRouter();
    }

    function test_deployProxyRegistersMarketReadableByOrderbook() public {
        address proxy = factory.deployProxy(
            0, address(mon), address(usdc), 1e10, 1e2, 1, 1e6, type(uint96).max, 30, 10, 0
        );

        (
            uint32 pricePrecision,
            uint96 sizePrecision,
            address baseAssetAddress,,
            address quoteAssetAddress,,,,,
            uint256 takerFeeBps,
            uint256 makerFeeBps
        ) = factory.verifiedMarket(proxy);

        assertEq(baseAssetAddress, address(mon));
        assertEq(quoteAssetAddress, address(usdc));
        assertEq(pricePrecision, 1e2);
        assertEq(sizePrecision, 1e10);
        assertEq(takerFeeBps, 30);
        assertEq(makerFeeBps, 10);
    }

    /// @notice Orderbook yang baru dideploy factory berperilaku sama seperti orderbook
    ///         listed lama begitu dibungkus adapter — agent bisa langsung swap di sana.
    function test_freshlyDeployedMarketTradesThroughAdapter() public {
        address proxy = factory.deployProxy(
            0, address(mon), address(usdc), 1e10, 1e2, 1, 1e6, type(uint96).max, 30, 10, 0
        );
        KuruMarketAdapter adapter = new KuruMarketAdapter(IKuruRouter(address(router)), proxy, address(0));

        router.setPrice(proxy, 2 * USDC, 1 * MON);
        mon.mint(address(router), 1_000_000 * MON);
        usdc.mint(address(router), 1_000_000 * USDC);

        (bytes32 agentId, address vault) = _registerAgent(alice, agentWallet, uint128(1_000 * USDC), 30 days);
        vm.prank(authority);
        custos.setMarketAllowed(agentId, address(adapter), true);

        vm.prank(agentWallet);
        uint128 charged = AgentVault(vault).executeSwap(address(adapter), true, uint128(500 * USDC), 0, 0);

        assertEq(charged, 500 * USDC);
        assertEq(mon.balanceOf(vault), 250 * MON);
    }
}
