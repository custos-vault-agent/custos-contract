// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {KuruMarketAdapter} from "../src/adapters/KuruMarketAdapter.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {IKuruRouter} from "../src/interfaces/IKuruRouter.sol";
import {ZeroAddress} from "../src/Errors.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockKuruOrderBook} from "./mocks/MockKuruOrderBook.sol";
import {MockKuruRouter} from "./mocks/MockKuruRouter.sol";
import {MockWrappedNative} from "./mocks/MockWrappedNative.sol";

/// @notice A Kuru market whose base is the native token. Kuru reports it as the zero
///         address and its router moves value, but Custos only ever moves ERC-20, so
///         the adapter wraps and unwraps inside the call. These tests hold it to that:
///         the vault sees WMON, and the adapter keeps neither WMON nor native.
contract KuruNativeAdapterTest is Base {
    MockKuruRouter internal router;
    MockKuruOrderBook internal orderbook;
    MockWrappedNative internal wmon;
    KuruMarketAdapter internal adapter;

    bytes32 internal agentId;
    address internal vault;

    function setUp() public override {
        super.setUp();

        wmon = new MockWrappedNative();
        router = new MockKuruRouter();
        // Base is the zero address: this is the native market shape from Kuru.
        orderbook = new MockKuruOrderBook(address(0), address(usdc));
        adapter = new KuruMarketAdapter(IKuruRouter(address(router)), address(orderbook), address(wmon));

        router.setPrice(address(orderbook), 2 * USDC, 1e18); // 1 native = 2 USDC
        usdc.mint(address(router), 1_000_000 * USDC);
        vm.deal(address(router), 1_000_000 ether); // the router pays the native leg

        // WMON is what the vault holds, so that is the token the oracle prices.
        vm.startPrank(authority);
        oracle.setFeed(address(wmon), AggregatorV3Interface(address(new MockAggregator(8, 2e8))), 1 days);
        vm.stopPrank();

        (agentId, vault) = _registerAgent(alice, agentWallet, uint128(1_000 * USDC), 30 days);
        vm.prank(authority);
        custos.setMarketAllowed(agentId, address(adapter), true);
    }

    function test_adapterReportsWrappedTokenAsBase() public view {
        assertTrue(adapter.nativeBase());
        assertEq(adapter.baseToken(), address(wmon));
        assertEq(adapter.quoteToken(), address(usdc));
    }

    function test_nativeMarketNeedsAWrappedToken() public {
        vm.expectRevert(ZeroAddress.selector);
        new KuruMarketAdapter(IKuruRouter(address(router)), address(orderbook), address(0));
    }

    function test_buyLandsAsWrappedTokenInTheVault() public {
        vm.prank(agentWallet);
        AgentVault(vault).executeSwap(address(adapter), true, uint128(400 * USDC), 0, 0);

        // 400 USDC at 2 USDC per unit is 200 units, wrapped.
        assertEq(wmon.balanceOf(vault), 200e18);
        assertEq(vault.balance, 0, "the vault never holds native");
        _assertAdapterIsEmpty();
    }

    function test_sellUnwrapsAndReturnsQuote() public {
        // Both legs share one period's allowance, so the round trip stays small.
        vm.prank(agentWallet);
        AgentVault(vault).executeSwap(address(adapter), true, uint128(200 * USDC), 0, 0);
        uint256 usdcBefore = usdc.balanceOf(vault);

        vm.prank(agentWallet);
        AgentVault(vault).executeSwap(address(adapter), false, uint128(100e18), 0, uint128(300 * USDC));

        assertEq(wmon.balanceOf(vault), 0);
        assertEq(usdc.balanceOf(vault) - usdcBefore, 200 * USDC);
        _assertAdapterIsEmpty();
    }

    /// A partial fill leaves native in the adapter mid-call. It must come back as WMON,
    /// or the vault would silently lose the unspent part of the sell.
    function test_partialSellReturnsTheRestAsWrappedToken() public {
        vm.prank(agentWallet);
        AgentVault(vault).executeSwap(address(adapter), true, uint128(200 * USDC), 0, 0);

        router.setSpendBps(6_000); // the router only spends 60% of what it is sent
        vm.prank(agentWallet);
        AgentVault(vault).executeSwap(address(adapter), false, uint128(100e18), 0, uint128(300 * USDC));

        assertEq(wmon.balanceOf(vault), 40e18, "40% of 100 comes back wrapped");
        _assertAdapterIsEmpty();
    }

    function test_valuationCountsTheWrappedPosition() public {
        uint256 before = AgentVault(vault).totalAssets();
        vm.prank(agentWallet);
        AgentVault(vault).executeSwap(address(adapter), true, uint128(400 * USDC), 0, 0);

        // 200 WMON at 2 USD each is the 400 USDC that left, so a fair buy is neutral.
        assertEq(AgentVault(vault).totalAssets(), before);
    }

    function _assertAdapterIsEmpty() internal view {
        assertEq(address(adapter).balance, 0, "adapter kept native");
        assertEq(wmon.balanceOf(address(adapter)), 0, "adapter kept WMON");
        assertEq(usdc.balanceOf(address(adapter)), 0, "adapter kept USDC");
    }
}
