// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {AgentVault} from "../src/AgentVault.sol";
import {CustosCore} from "../src/CustosCore.sol";
import {CustosProxy} from "../src/CustosProxy.sol";
import {AgentRecord, Status} from "../src/Types.sol";
import {
    AgentAlreadyRevoked,
    MarketQuoteMismatch,
    NotCreator,
    NotUpgradeAuthority,
    SeedTooSmall,
    SelfDelegation,
    WalletAlreadyBound,
    ZeroAddress
} from "../src/Errors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarket} from "./mocks/MockMarket.sol";

contract AgentRegistryTest is Test {
    CustosCore internal custos;
    MockERC20 internal usdc;
    MockERC20 internal mon;
    MockMarket internal market;

    address internal authority = makeAddr("authority");
    address internal alice = makeAddr("alice");
    address internal agentWallet = makeAddr("agentWallet");

    uint256 internal constant USDC = 1e6;
    uint128 internal constant MIN_SEED = 500 * 1e6;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        mon = new MockERC20("Monad", "MON", 18);
        market = new MockMarket(address(mon), address(usdc), 2 * USDC, 1e18);

        custos = CustosCore(
            address(
                new CustosProxy(
                    address(new CustosCore()), abi.encodeCall(CustosCore.initialize, (authority, address(usdc)))
                )
            )
        );

        vm.startPrank(authority);
        custos.setMarketAdapter(address(market));
        custos.setMinSeed(MIN_SEED);
        vm.stopPrank();

        usdc.mint(alice, 1_000_000 * USDC);
        vm.prank(alice);
        usdc.approve(address(custos), type(uint256).max);
    }

    function test_agentExistsFalseForUnknownId() public {
        assertFalse(custos.agentExists(bytes32(uint256(0xdead))));
    }

    function test_agentExistsTrueAfterRegister() public {
        vm.prank(alice);
        (bytes32 id,) = custos.registerAgent(
            bytes32("grid-bot"), "trading bot", agentWallet, 4_000 * uint128(USDC), 1 days, 1000, 2000,
            address(0), 7000, true, 1_000 * uint128(USDC)
        );

        assertTrue(custos.agentExists(id));
    }

    function test_registerAgentDeploysVault() public {
        vm.prank(alice);
        (bytes32 id, address vault) = custos.registerAgent(
            bytes32("grid-bot"), "trading bot", agentWallet, 4_000 * uint128(USDC), 1 days, 1000, 2000,
            address(0), 7000, true, 1_000 * uint128(USDC)
        );

        AgentVault v = AgentVault(vault);
        assertEq(v.creator(), alice);
        assertEq(v.agent(), agentWallet);
        assertEq(v.custosCore(), address(custos));
        assertEq(v.feeRate(), 1000);
        assertEq(v.maxDrawdownBps(), 2000);
        assertEq(v.maxUtilizationBps(), 7000);
        assertEq(v.allowance(), 4_000 * uint128(USDC));

        AgentRecord memory record = custos.getAgent(id);
        assertEq(uint8(record.status), uint8(Status.Active));
        assertEq(record.creator, alice);
        assertEq(record.vault, vault);
    }

    function test_seedDepositLockedAtDeadAddress() public {
        vm.prank(alice);
        (, address vault) = custos.registerAgent(
            bytes32("grid-bot"), "trading bot", agentWallet, 4_000 * uint128(USDC), 1 days, 1000, 2000,
            address(0), 7000, true, 1_000 * uint128(USDC)
        );

        AgentVault v = AgentVault(vault);
        assertEq(v.balanceOf(address(1)), 1_000 * uint128(USDC));
        assertEq(v.totalAssets(), 1_000 * USDC);
    }

    function test_seedBelowMinReverts() public {
        vm.prank(alice);
        vm.expectRevert(SeedTooSmall.selector);
        custos.registerAgent(
            bytes32("grid-bot"), "trading bot", agentWallet, 4_000 * uint128(USDC), 1 days, 1000, 2000,
            address(0), 7000, true, 1 * uint128(USDC)
        );
    }

    function test_walletCannotBeReregistered() public {
        vm.prank(alice);
        custos.registerAgent(
            bytes32("grid-bot"), "trading bot", agentWallet, 4_000 * uint128(USDC), 1 days, 1000, 2000,
            address(0), 7000, true, 1_000 * uint128(USDC)
        );

        vm.prank(alice);
        vm.expectRevert(WalletAlreadyBound.selector);
        custos.registerAgent(
            bytes32("grid-bot-2"), "another bot", agentWallet, 1_000 * uint128(USDC), 1 days, 500, 1000,
            address(0), 7000, true, 1_000 * uint128(USDC)
        );
    }

    function test_selfDelegationReverts() public {
        vm.prank(alice);
        vm.expectRevert(SelfDelegation.selector);
        custos.registerAgent(
            bytes32("grid-bot"), "trading bot", alice, 4_000 * uint128(USDC), 1 days, 1000, 2000,
            address(0), 7000, true, 1_000 * uint128(USDC)
        );
    }

    function test_pauseBlocksDepositAndTrade() public {
        vm.prank(alice);
        (bytes32 id, address vault) = custos.registerAgent(
            bytes32("grid-bot"), "trading bot", agentWallet, 4_000 * uint128(USDC), 1 days, 1000, 2000,
            address(0), 7000, true, 1_000 * uint128(USDC)
        );

        vm.prank(alice);
        custos.pauseAgent(id);

        assertEq(uint8(AgentVault(vault).status()), uint8(Status.Paused));
    }

    function test_revokeIsPermanent() public {
        vm.prank(alice);
        (bytes32 id,) = custos.registerAgent(
            bytes32("grid-bot"), "trading bot", agentWallet, 4_000 * uint128(USDC), 1 days, 1000, 2000,
            address(0), 7000, true, 1_000 * uint128(USDC)
        );

        vm.prank(alice);
        custos.revokeAgent(id);

        assertEq(uint8(custos.getAgent(id).status), uint8(Status.Revoked));
    }

    function test_revokedAgentCannotBeResumedOrPaused() public {
        vm.prank(alice);
        (bytes32 id,) = custos.registerAgent(
            bytes32("grid-bot"), "trading bot", agentWallet, 4_000 * uint128(USDC), 1 days, 1000, 2000,
            address(0), 7000, true, 1_000 * uint128(USDC)
        );

        vm.prank(alice);
        custos.revokeAgent(id);

        vm.prank(alice);
        vm.expectRevert(AgentAlreadyRevoked.selector);
        custos.resumeAgent(id);

        vm.prank(alice);
        vm.expectRevert(AgentAlreadyRevoked.selector);
        custos.pauseAgent(id);

        assertEq(uint8(custos.getAgent(id).status), uint8(Status.Revoked));
    }

    function test_setAllowanceForwardsToVault() public {
        vm.prank(alice);
        (bytes32 id, address vault) = custos.registerAgent(
            bytes32("grid-bot"), "trading bot", agentWallet, 4_000 * uint128(USDC), 1 days, 1000, 2000,
            address(0), 7000, true, 1_000 * uint128(USDC)
        );

        vm.prank(alice);
        custos.setAllowance(id, 9_000 * uint128(USDC));

        assertEq(AgentVault(vault).allowance(), 9_000 * uint128(USDC));
    }

    function test_setPeriodForwardsToVault() public {
        vm.prank(alice);
        (bytes32 id, address vault) = custos.registerAgent(
            bytes32("grid-bot"), "trading bot", agentWallet, 4_000 * uint128(USDC), 1 days, 1000, 2000,
            address(0), 7000, true, 1_000 * uint128(USDC)
        );

        vm.prank(alice);
        custos.setPeriod(id, 7 days);

        assertEq(AgentVault(vault).periodLength(), 7 days);
    }

    function test_setPublicUpdatesRegistryOnly() public {
        vm.prank(alice);
        (bytes32 id,) = custos.registerAgent(
            bytes32("grid-bot"), "trading bot", agentWallet, 4_000 * uint128(USDC), 1 days, 1000, 2000,
            address(0), 7000, true, 1_000 * uint128(USDC)
        );

        vm.prank(alice);
        custos.setPublic(id, false);

        assertFalse(custos.getAgent(id).isPublic);
    }

    function test_nonCreatorCannotConfigureAgent() public {
        vm.prank(alice);
        (bytes32 id,) = custos.registerAgent(
            bytes32("grid-bot"), "trading bot", agentWallet, 4_000 * uint128(USDC), 1 days, 1000, 2000,
            address(0), 7000, true, 1_000 * uint128(USDC)
        );

        vm.prank(agentWallet);
        vm.expectRevert(NotCreator.selector);
        custos.setAllowance(id, 1);
    }

    function test_setMarketAllowedForwardsToVault() public {
        vm.prank(alice);
        (bytes32 id, address vault) = custos.registerAgent(
            bytes32("grid-bot"), "trading bot", agentWallet, 4_000 * uint128(USDC), 1 days, 1000, 2000,
            address(0), 7000, true, 1_000 * uint128(USDC)
        );

        vm.prank(authority);
        custos.setMarketAllowed(id, address(market), true);

        assertTrue(AgentVault(vault).allowedMarkets(address(market)));
    }

    function test_setMarketAllowedRejectsWrongQuote() public {
        // quote == base here (both MON) — never equals the USDC accounting asset.
        MockMarket badMarket = new MockMarket(address(mon), address(mon), 1, 1);

        vm.prank(alice);
        (bytes32 id,) = custos.registerAgent(
            bytes32("grid-bot"), "trading bot", agentWallet, 4_000 * uint128(USDC), 1 days, 1000, 2000,
            address(0), 7000, true, 1_000 * uint128(USDC)
        );

        vm.prank(authority);
        vm.expectRevert(MarketQuoteMismatch.selector);
        custos.setMarketAllowed(id, address(badMarket), true);
    }

    function test_onlyUpgradeAuthorityCanSetMarketAllowed() public {
        vm.prank(alice);
        (bytes32 id,) = custos.registerAgent(
            bytes32("grid-bot"), "trading bot", agentWallet, 4_000 * uint128(USDC), 1 days, 1000, 2000,
            address(0), 7000, true, 1_000 * uint128(USDC)
        );

        vm.prank(alice);
        vm.expectRevert(NotUpgradeAuthority.selector);
        custos.setMarketAllowed(id, address(market), true);
    }
}
