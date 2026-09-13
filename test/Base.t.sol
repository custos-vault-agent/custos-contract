// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {CustosLogic} from "../src/CustosLogic.sol";
import {CustosProxy} from "../src/CustosProxy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarket} from "./mocks/MockMarket.sol";

/// @notice Harness bersama: proxy terpasang, token siap, satu pasar diizinkan.
abstract contract Base is Test {
    CustosLogic internal custos;
    address internal implementation;

    MockERC20 internal usdc; // aset akuntansi, 6 desimal
    MockERC20 internal mon; // base, 18 desimal
    MockMarket internal market;

    address internal authority = makeAddr("authority");
    address internal receiver = makeAddr("auroraReceiver");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal agentWallet = makeAddr("agentWallet");

    uint256 internal constant USDC = 1e6;
    uint256 internal constant MON = 1e18;

    function setUp() public virtual {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        mon = new MockERC20("Monad", "MON", 18);

        implementation = address(new CustosLogic());
        custos = CustosLogic(
            address(
                new CustosProxy(
                    implementation,
                    abi.encodeCall(CustosLogic.initialize, (authority, address(usdc)))
                )
            )
        );

        // 1 MON = 2 USDC.
        market = new MockMarket(address(mon), address(usdc), 2 * USDC, 1 * MON);
        mon.mint(address(market), 1_000_000 * MON);
        usdc.mint(address(market), 1_000_000 * USDC);

        vm.startPrank(authority);
        custos.setAuroraReceiver(receiver);
        custos.setMarketAllowed(address(market), true);
        vm.stopPrank();
    }

    /// @dev Meniru jalur Aurora: transfer lalu kredit dalam satu transaksi. Urutan itu
    ///      wajib — `creditDeposit` mengukur selisih saldo, bukan menerima klaim.
    function _deposit(address owner, MockERC20 token, uint256 amount) internal {
        token.mint(address(custos), amount);
        vm.prank(receiver);
        custos.creditDeposit(owner, address(token));
    }

    function _registerAgent(address owner, address wallet, uint128 allowance, uint32 period)
        internal
        returns (bytes32 id)
    {
        vm.prank(owner);
        id = custos.registerAgent(bytes32("bot"), "trading bot", wallet, allowance, period);
    }
}
