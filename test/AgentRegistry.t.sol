// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {AgentVault} from "../src/AgentVault.sol";
import {CustosCore} from "../src/CustosCore.sol";
import {CustosProxy} from "../src/CustosProxy.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {AgentRecord, Status} from "../src/Types.sol";
import {
    AgentAlreadyRevoked,
    MarketAlreadyCurated,
    MarketNotCurated,
    MarketQuoteMismatch,
    MarketStillHeld,
    NotCreator,
    NotUpgradeAuthority,
    SeedTooSmall,
    SelfDelegation,
    TooManyCuratedMarkets,
    WalletAlreadyBound
} from "../src/Errors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarket} from "./mocks/MockMarket.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";

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
                    address(new CustosCore()),
                    abi.encodeCall(CustosCore.initialize, (authority, address(usdc)))
                )
            )
        );

        PriceOracle oracle = new PriceOracle(authority, address(usdc));
        vm.startPrank(authority);
        oracle.setFeed(address(mon), AggregatorV3Interface(address(new MockAggregator(8, 2e8))), 1 days);
        custos.setMarketAdapter(address(market));
        custos.setVaultFactory(address(new VaultFactory(address(custos))));
        custos.setPriceOracle(address(oracle));
        custos.setMinSeed(MIN_SEED);
        vm.stopPrank();

        usdc.mint(alice, 1_000_000 * USDC);
        vm.prank(alice);
        usdc.approve(address(custos), type(uint256).max);
    }

    function test_registerAgentDeploysVault() public {
        vm.prank(alice);
        (bytes32 id, address vault) = custos.registerAgent(
            bytes32("grid-bot"),
            "trading bot",
            agentWallet,
            4_000 * uint128(USDC),
            1 days,
            1000,
            2000,
            address(0),
            7000,
            true,
            1_000 * uint128(USDC)
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
            bytes32("grid-bot"),
            "trading bot",
            agentWallet,
            4_000 * uint128(USDC),
            1 days,
            1000,
            2000,
            address(0),
            7000,
            true,
            1_000 * uint128(USDC)
        );

        AgentVault v = AgentVault(vault);
        assertEq(v.balanceOf(address(1)), 1_000 * uint128(USDC));
        assertEq(v.totalAssets(), 1_000 * USDC);
    }

    function test_seedBelowMinReverts() public {
        vm.prank(alice);
        vm.expectRevert(SeedTooSmall.selector);
        custos.registerAgent(
            bytes32("grid-bot"),
            "trading bot",
            agentWallet,
            4_000 * uint128(USDC),
            1 days,
            1000,
            2000,
            address(0),
            7000,
            true,
            1 * uint128(USDC)
        );
    }

    function test_walletCannotBeReregistered() public {
        vm.prank(alice);
        custos.registerAgent(
            bytes32("grid-bot"),
            "trading bot",
            agentWallet,
            4_000 * uint128(USDC),
            1 days,
            1000,
            2000,
            address(0),
            7000,
            true,
            1_000 * uint128(USDC)
        );

        vm.prank(alice);
        vm.expectRevert(WalletAlreadyBound.selector);
        custos.registerAgent(
            bytes32("grid-bot-2"),
            "another bot",
            agentWallet,
            1_000 * uint128(USDC),
            1 days,
            500,
            1000,
            address(0),
            7000,
            true,
            1_000 * uint128(USDC)
        );
    }

    function test_selfDelegationReverts() public {
        vm.prank(alice);
        vm.expectRevert(SelfDelegation.selector);
        custos.registerAgent(
            bytes32("grid-bot"),
            "trading bot",
            alice,
            4_000 * uint128(USDC),
            1 days,
            1000,
            2000,
            address(0),
            7000,
            true,
            1_000 * uint128(USDC)
        );
    }

    function test_pauseBlocksDepositAndTrade() public {
        vm.prank(alice);
        (bytes32 id, address vault) = custos.registerAgent(
            bytes32("grid-bot"),
            "trading bot",
            agentWallet,
            4_000 * uint128(USDC),
            1 days,
            1000,
            2000,
            address(0),
            7000,
            true,
            1_000 * uint128(USDC)
        );

        vm.prank(alice);
        custos.pauseAgent(id);

        assertEq(uint8(AgentVault(vault).status()), uint8(Status.Paused));
    }

    function test_revokeIsPermanent() public {
        vm.prank(alice);
        (bytes32 id,) = custos.registerAgent(
            bytes32("grid-bot"),
            "trading bot",
            agentWallet,
            4_000 * uint128(USDC),
            1 days,
            1000,
            2000,
            address(0),
            7000,
            true,
            1_000 * uint128(USDC)
        );

        vm.prank(alice);
        custos.revokeAgent(id);

        assertEq(uint8(custos.getAgent(id).status), uint8(Status.Revoked));
    }

    function test_revokedAgentCannotBeResumedOrPaused() public {
        vm.prank(alice);
        (bytes32 id,) = custos.registerAgent(
            bytes32("grid-bot"),
            "trading bot",
            agentWallet,
            4_000 * uint128(USDC),
            1 days,
            1000,
            2000,
            address(0),
            7000,
            true,
            1_000 * uint128(USDC)
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
            bytes32("grid-bot"),
            "trading bot",
            agentWallet,
            4_000 * uint128(USDC),
            1 days,
            1000,
            2000,
            address(0),
            7000,
            true,
            1_000 * uint128(USDC)
        );

        vm.prank(alice);
        custos.setAllowance(id, 9_000 * uint128(USDC));

        assertEq(AgentVault(vault).allowance(), 9_000 * uint128(USDC));
    }

    function test_setPeriodForwardsToVault() public {
        vm.prank(alice);
        (bytes32 id, address vault) = custos.registerAgent(
            bytes32("grid-bot"),
            "trading bot",
            agentWallet,
            4_000 * uint128(USDC),
            1 days,
            1000,
            2000,
            address(0),
            7000,
            true,
            1_000 * uint128(USDC)
        );

        vm.prank(alice);
        custos.setPeriod(id, 7 days);

        assertEq(AgentVault(vault).periodLength(), 7 days);
    }

    function test_setPublicUpdatesRegistryOnly() public {
        vm.prank(alice);
        (bytes32 id,) = custos.registerAgent(
            bytes32("grid-bot"),
            "trading bot",
            agentWallet,
            4_000 * uint128(USDC),
            1 days,
            1000,
            2000,
            address(0),
            7000,
            true,
            1_000 * uint128(USDC)
        );

        vm.prank(alice);
        custos.setPublic(id, false);

        assertFalse(custos.getAgent(id).isPublic);
    }

    function test_nonCreatorCannotConfigureAgent() public {
        vm.prank(alice);
        (bytes32 id,) = custos.registerAgent(
            bytes32("grid-bot"),
            "trading bot",
            agentWallet,
            4_000 * uint128(USDC),
            1 days,
            1000,
            2000,
            address(0),
            7000,
            true,
            1_000 * uint128(USDC)
        );

        vm.prank(agentWallet);
        vm.expectRevert(NotCreator.selector);
        custos.setAllowance(id, 1);
    }

    function test_setMarketAllowedForwardsToVault() public {
        vm.prank(alice);
        (bytes32 id, address vault) = custos.registerAgent(
            bytes32("grid-bot"),
            "trading bot",
            agentWallet,
            4_000 * uint128(USDC),
            1 days,
            1000,
            2000,
            address(0),
            7000,
            true,
            1_000 * uint128(USDC)
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
            bytes32("grid-bot"),
            "trading bot",
            agentWallet,
            4_000 * uint128(USDC),
            1 days,
            1000,
            2000,
            address(0),
            7000,
            true,
            1_000 * uint128(USDC)
        );

        vm.prank(authority);
        vm.expectRevert(MarketQuoteMismatch.selector);
        custos.setMarketAllowed(id, address(badMarket), true);
    }

    function test_onlyUpgradeAuthorityCanSetMarketAllowed() public {
        vm.prank(alice);
        (bytes32 id,) = custos.registerAgent(
            bytes32("grid-bot"),
            "trading bot",
            agentWallet,
            4_000 * uint128(USDC),
            1 days,
            1000,
            2000,
            address(0),
            7000,
            true,
            1_000 * uint128(USDC)
        );

        vm.prank(alice);
        vm.expectRevert(NotUpgradeAuthority.selector);
        custos.setMarketAllowed(id, address(market), true);
    }

    function _register(address wallet) internal returns (address vault) {
        vm.prank(alice);
        (, vault) = custos.registerAgent(
            bytes32("bot"),
            "d",
            wallet,
            4_000 * uint128(USDC),
            1 days,
            1000,
            2000,
            address(0),
            7000,
            true,
            1_000 * uint128(USDC)
        );
    }

    function test_curatedMarketIsAllowedOnANewVault() public {
        vm.prank(authority);
        custos.setCuratedMarket(address(market), true);

        AgentVault v = AgentVault(_register(agentWallet));
        assertTrue(v.allowedMarkets(address(market)));
        // One curated market means one iteration and one allowed market.
        assertEq(custos.curatedMarkets().length, 1);
        assertFalse(v.allowedMarkets(address(0xdead)));
    }

    function test_withoutCurationANewVaultAllowsNothing() public {
        AgentVault v = AgentVault(_register(agentWallet));
        assertFalse(v.allowedMarkets(address(market)));
    }

    function test_curationIsCappedAndRejectsDuplicates() public {
        vm.startPrank(authority);
        for (uint256 i = 0; i < 8; i++) {
            custos.setCuratedMarket(
                address(new MockMarket(address(mon), address(usdc), 2 * USDC, 1e18)), true
            );
        }
        assertEq(custos.curatedMarkets().length, 8);

        MockMarket ninth = new MockMarket(address(mon), address(usdc), 2 * USDC, 1e18);
        vm.expectRevert(TooManyCuratedMarkets.selector);
        custos.setCuratedMarket(address(ninth), true);

        address first = custos.curatedMarkets()[0];
        vm.expectRevert(MarketAlreadyCurated.selector);
        custos.setCuratedMarket(first, true);
        vm.stopPrank();
    }

    function test_uncuratingStopsNewVaultsButKeepsExistingOnes() public {
        vm.prank(authority);
        custos.setCuratedMarket(address(market), true);
        AgentVault before = AgentVault(_register(agentWallet));

        vm.prank(authority);
        custos.setCuratedMarket(address(market), false);
        AgentVault later = AgentVault(_register(makeAddr("agentWallet2")));

        assertTrue(before.allowedMarkets(address(market)));
        assertFalse(later.allowedMarkets(address(market)));
        assertEq(custos.curatedMarkets().length, 0);
    }

    function test_aMarketWithoutAFeedIsSkippedInsteadOfBrickingRegistration() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        MockMarket unpriced = new MockMarket(address(other), address(usdc), 2 * USDC, 1e18);
        vm.startPrank(authority);
        custos.setCuratedMarket(address(market), true);
        custos.setCuratedMarket(address(unpriced), true);
        vm.stopPrank();

        AgentVault v = AgentVault(_register(agentWallet));
        assertTrue(v.allowedMarkets(address(market)));
        assertFalse(v.allowedMarkets(address(unpriced)));
    }

    function test_onlyAuthorityCurates() public {
        vm.prank(alice);
        vm.expectRevert(NotUpgradeAuthority.selector);
        custos.setCuratedMarket(address(market), true);
    }

    function test_curationRejectsANonUsdcQuote() public {
        MockMarket wrong = new MockMarket(address(usdc), address(mon), 2 * USDC, 1e18);
        vm.prank(authority);
        vm.expectRevert(MarketQuoteMismatch.selector);
        custos.setCuratedMarket(address(wrong), true);
    }

    function test_creatorPicksACuratedMarket() public {
        vm.prank(authority);
        custos.setCuratedMarket(address(market), true);
        AgentVault v = AgentVault(_register(agentWallet));
        // Read the id before pranking: a view call would consume the prank.
        bytes32 id = custos.agentAt(0);

        vm.prank(authority);
        custos.setMarketAllowed(id, address(market), false);
        assertFalse(v.allowedMarkets(address(market)));

        vm.prank(alice);
        custos.setAgentMarket(id, address(market), true);
        assertTrue(v.allowedMarkets(address(market)));

        vm.prank(alice);
        custos.setAgentMarket(id, address(market), false);
        assertFalse(v.allowedMarkets(address(market)));
    }

    function test_creatorCannotPickAnUncuratedMarket() public {
        _register(agentWallet);
        bytes32 id = custos.agentAt(0);
        vm.prank(alice);
        vm.expectRevert(MarketNotCurated.selector);
        custos.setAgentMarket(id, address(market), true);
    }

    function test_onlyTheCreatorPicksMarkets() public {
        vm.prank(authority);
        custos.setCuratedMarket(address(market), true);
        _register(agentWallet);
        bytes32 id = custos.agentAt(0);

        vm.prank(makeAddr("intruder"));
        vm.expectRevert(NotCreator.selector);
        custos.setAgentMarket(id, address(market), true);
    }

    function test_creatorCannotStrandAHeldBase() public {
        vm.prank(authority);
        custos.setCuratedMarket(address(market), true);
        address vault = _register(agentWallet);
        bytes32 id = custos.agentAt(0);
        mon.mint(vault, 1e18);

        vm.prank(alice);
        vm.expectRevert(MarketStillHeld.selector);
        custos.setAgentMarket(id, address(market), false);

        // The authority keeps the emergency override.
        vm.prank(authority);
        custos.setMarketAllowed(id, address(market), false);
        assertFalse(AgentVault(vault).allowedMarkets(address(market)));
    }

    function test_revokedAgentCannotChangeMarkets() public {
        vm.prank(authority);
        custos.setCuratedMarket(address(market), true);
        _register(agentWallet);
        bytes32 id = custos.agentAt(0);

        vm.startPrank(alice);
        custos.revokeAgent(id);
        vm.expectRevert(AgentAlreadyRevoked.selector);
        custos.setAgentMarket(id, address(market), true);
        vm.stopPrank();
    }
}
