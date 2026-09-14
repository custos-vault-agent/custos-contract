// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {CustosCore} from "../src/CustosCore.sol";
import {CustosProxy} from "../src/CustosProxy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarket} from "./mocks/MockMarket.sol";

/// @notice Harness bersama: proxy terpasang, market adapter + minSeed diset, token
///         siap. Beda dari v0.1: tidak ada lagi shared vault untuk di-deposit —
///         setiap test yang butuh dana di suatu vault memanggil `_registerAgent`,
///         yang otomatis membuat dan menyeed vault-nya sendiri.
abstract contract Base is Test {
    CustosCore internal custos;
    address internal implementation;

    MockERC20 internal usdc; // aset akuntansi, 6 desimal
    MockERC20 internal mon; // base, 18 desimal
    MockMarket internal market;

    address internal authority = makeAddr("authority");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal agentWallet = makeAddr("agentWallet");
    address internal auroraReceiver = makeAddr("auroraReceiver");

    uint256 internal constant USDC = 1e6;
    uint256 internal constant MON = 1e18;
    uint128 internal constant MIN_SEED = 500 * 1e6;

    function setUp() public virtual {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        mon = new MockERC20("Monad", "MON", 18);

        implementation = address(new CustosCore());
        custos = CustosCore(
            address(
                new CustosProxy(
                    implementation, abi.encodeCall(CustosCore.initialize, (authority, address(usdc)))
                )
            )
        );

        // 1 MON = 2 USDC.
        market = new MockMarket(address(mon), address(usdc), 2 * USDC, 1 * MON);
        mon.mint(address(market), 1_000_000 * MON);
        usdc.mint(address(market), 1_000_000 * USDC);

        vm.startPrank(authority);
        custos.setMarketAdapter(address(market));
        custos.setMinSeed(MIN_SEED);
        vm.stopPrank();

        vm.prank(authority);
        custos.setAuroraReceiver(auroraReceiver);
    }

    /// @dev Mints the creator enough USDC to cover the seed, approves, registers.
    ///      Returns the vault address too — almost every caller needs it immediately.
    function _registerAgent(address creator, address wallet, uint128 allowance, uint32 period)
        internal
        returns (bytes32 id, address vault)
    {
        usdc.mint(creator, 1_000 * USDC);
        vm.prank(creator);
        usdc.approve(address(custos), type(uint256).max);

        vm.prank(creator);
        (id, vault) = custos.registerAgent(
            bytes32("bot"),
            "trading bot",
            wallet,
            allowance,
            period,
            1000, // feeRate 10%
            2000, // maxDrawdownBps 20%
            address(0), // yieldSource disabled
            7000, // maxUtilizationBps 70%
            true, // isPublic
            uint128(1_000 * USDC) // seedAmount
        );
    }

    function _allowMarket(bytes32 id) internal {
        vm.prank(authority);
        custos.setMarketAllowed(id, address(market), true);
    }
}
