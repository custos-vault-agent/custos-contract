// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {Status} from "../src/Types.sol";
import {IMarket} from "../src/interfaces/IMarket.sol";
import {IYieldSource} from "../src/interfaces/IYieldSource.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {
    AgentCannotCallThis,
    FeedInvalid,
    NoPriceFeed,
    NotUpgradeAuthority,
    OracleQuoteMismatch,
    Paused,
    SeedTooSmall,
    SlippageExceeded,
    StalePrice,
    SwapDrawdownExceeded,
    YieldSourceNotAllowed
} from "../src/Errors.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarket} from "./mocks/MockMarket.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Yield source jahat: menyimpan semua, melapor nol.
contract RugYield is IYieldSource {
    IERC20 immutable t;
    address immutable thief;

    constructor(IERC20 t_, address thief_) {
        t = t_;
        thief = thief_;
    }

    function deposit(uint256 a) external returns (uint256) {
        t.transferFrom(msg.sender, thief, a);
        return a;
    }

    function withdraw(uint256) external pure returns (uint256) {
        return 0;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}

/// @notice Regresi untuk temuan security review 2026-09-18 (H1/H2/H3).
contract SecurityRegressionTest is Base {
    function _register(address yieldSource) internal returns (bytes32 id, address vault) {
        usdc.mint(alice, 1_000 * USDC);
        vm.startPrank(alice);
        usdc.approve(address(custos), type(uint256).max);
        (id, vault) = custos.registerAgent(
            bytes32("x"),
            "",
            agentWallet,
            type(uint128).max,
            0,
            1000,
            2000,
            yieldSource,
            7000,
            true,
            uint128(1_000 * USDC)
        );
        vm.stopPrank();
    }

    /* ------------------------------- H1 ------------------------------------ */

    function test_H1_unlistedYieldSourceRejected() public {
        RugYield rug = new RugYield(IERC20(address(usdc)), alice);
        usdc.mint(alice, 1_000 * USDC);
        vm.startPrank(alice);
        usdc.approve(address(custos), type(uint256).max);
        vm.expectRevert(YieldSourceNotAllowed.selector);
        custos.registerAgent(
            bytes32("x"), "", agentWallet, 0, 0, 0, 0, address(rug), 5000, true, uint128(1_000 * USDC)
        );
        vm.stopPrank();
    }

    function test_H1_allowlistedYieldSourceAccepted() public {
        RugYield ys = new RugYield(IERC20(address(usdc)), alice);
        vm.prank(authority);
        custos.setYieldSourceAllowed(address(ys), true);
        (, address vault) = _register(address(ys));
        assertEq(AgentVault(vault).yieldSource(), address(ys));
    }

    /* ------------------------------- H3 ------------------------------------ */

    function test_H3_manualPauseResumeDoesNotResetHwm() public {
        (bytes32 id, address vault) = _register(address(0));
        _allowMarket(id);
        uint256 hwm0 = AgentVault(vault).highWaterMark();

        // Loss nyata: market hanya membayar 50% MON.
        market.setPayoutBps(5_000);
        vm.prank(agentWallet);
        AgentVault(vault).executeSwap(address(market), true, uint128(200 * USDC), 0, 0); // -100 dari 1000 = 10% < 20%
        assertEq(uint8(AgentVault(vault).status()), uint8(Status.Active), "breaker must not trip at 10%");
        assertEq(AgentVault(vault).highWaterMark(), hwm0);

        vm.startPrank(alice);
        custos.pauseAgent(id);
        custos.resumeAgent(id);
        vm.stopPrank();
        assertEq(AgentVault(vault).highWaterMark(), hwm0, "creator cannot lower HWM without a breaker");
    }

    function test_H3_resumeAfterBreakerStillResetsHwm() public {
        (bytes32 id, address vault) = _register(address(0));
        _allowMarket(id);
        uint256 hwm0 = AgentVault(vault).highWaterMark();

        vm.prank(agentWallet);
        AgentVault(vault).executeSwap(address(market), true, uint128(500 * USDC), 0, 0); // 250 MON
        monFeed.set(1e8); // MON halves: 500 + 250 = 750 → 25% > 20%
        vm.prank(agentWallet);
        AgentVault(vault).executeSwap(address(market), true, uint128(1 * USDC), 0, 0);
        assertEq(uint8(AgentVault(vault).status()), uint8(Status.Paused));
        assertTrue(AgentVault(vault).breakerTripped());

        vm.prank(alice);
        custos.resumeAgent(id);
        assertLt(AgentVault(vault).highWaterMark(), hwm0);
        assertFalse(AgentVault(vault).breakerTripped());
    }

    /* ------------------------------- H2 ------------------------------------ */

    function test_H2_fairBuyKeepsSharePriceAndPosition() public {
        (bytes32 id, address vault) = _register(address(0));
        _allowMarket(id);
        uint256 before = AgentVault(vault).totalAssets();

        vm.prank(agentWallet);
        AgentVault(vault).executeSwap(address(market), true, uint128(600 * USDC), 0, 0);

        assertEq(AgentVault(vault).totalAssets(), before, "MON dinilai 2 USD, sama dengan yang dibayar");
        assertEq(uint8(AgentVault(vault).status()), uint8(Status.Active), "no false breaker");
        assertEq(AgentVault(vault).heldBases(0), address(mon));

        // Harga MON turun 50% → posisi 300 MON senilai 300 → drawdown 30% → breaker pada swap berikutnya.
        monFeed.set(1e8);
        assertEq(AgentVault(vault).totalAssets(), 700 * USDC);
    }

    function test_H2_marketWithoutFeedRejected() public {
        (bytes32 id,) = _register(address(0));
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        MockMarket m = new MockMarket(address(other), address(usdc), 1 * USDC, 1e18);
        vm.prank(authority);
        vm.expectRevert(NoPriceFeed.selector);
        custos.setMarketAllowed(id, address(m), true);
    }

    function test_H2_staleFeedBlocksValuationOnlyWhenHoldingBase() public {
        (bytes32 id, address vault) = _register(address(0));
        _allowMarket(id);
        // via_ir meng-hoist `block.timestamp`, jadi pakai vm.getBlockTimestamp().
        vm.warp(vm.getBlockTimestamp() + 2 days); // feed 1 day maxStaleness → basi
        AgentVault(vault).totalAssets(); // flat vault: tidak tersentuh

        monFeed.set(2e8);
        vm.prank(agentWallet);
        AgentVault(vault).executeSwap(address(market), true, uint128(100 * USDC), 0, 0);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.expectRevert(StalePrice.selector);
        AgentVault(vault).totalAssets();
    }

    function test_H2_oracleRejectsBadFeeds() public {
        PriceOracle o = new PriceOracle(address(this), address(usdc));
        MockAggregator bad = new MockAggregator(8, 0); // answer 0
        vm.expectRevert(FeedInvalid.selector);
        o.setFeed(address(mon), AggregatorV3Interface(address(bad)), 1 days);

        MockAggregator noAgg = new MockAggregator(8, 2e8);
        noAgg.setAggregator(address(0)); // bukan proxy Chainlink asli
        vm.expectRevert(FeedInvalid.selector);
        o.setFeed(address(mon), AggregatorV3Interface(address(noAgg)), 1 days);

        MockAggregator stale = new MockAggregator(8, 2e8);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(StalePrice.selector);
        o.setFeed(address(mon), AggregatorV3Interface(address(stale)), 1 days);
    }

    function test_H2_valueOfDecimalsMath() public view {
        // 1.5 MON (18 dec) @ 2 USD (8 dec) → 3 USDC (6 dec)
        assertEq(oracle.valueOf(address(mon), 1.5e18), 3 * USDC);
    }

    function test_H2_setPriceOracleRejectsWrongQuote() public {
        PriceOracle wrong = new PriceOracle(authority, address(mon));
        vm.prank(authority);
        vm.expectRevert(OracleQuoteMismatch.selector);
        custos.setPriceOracle(address(wrong));
    }

    /* ---------------------------- M1 / M2 / M4 ----------------------------- */

    function test_M1_singleSwapLosingMoreThanDrawdownReverts() public {
        (bytes32 id, address vault) = _register(address(0));
        _allowMarket(id);
        market.setPayoutBps(5_000); // market pays half: a 50% loss inside one swap
        vm.prank(agentWallet);
        vm.expectRevert(SwapDrawdownExceeded.selector);
        AgentVault(vault).executeSwap(address(market), true, uint128(600 * USDC), 0, 0);
        // A small loss on the same market still goes through and trips nothing.
        market.setPayoutBps(9_000);
        vm.prank(agentWallet);
        AgentVault(vault).executeSwap(address(market), true, uint128(100 * USDC), 0, 0);
        assertEq(uint8(AgentVault(vault).status()), uint8(Status.Active));
    }

    function test_M2_vaultEnforcesMinAmountOutItself() public {
        (bytes32 id, address vault) = _register(address(0));
        _allowMarket(id);
        // A market that ignores minAmountOut and delivers nothing: the vault must
        // catch the shortfall on its own balance delta.
        vm.mockCall(address(market), abi.encodeWithSelector(IMarket.swap.selector), abi.encode(uint256(0)));
        vm.prank(agentWallet);
        vm.expectRevert(SlippageExceeded.selector);
        AgentVault(vault).executeSwap(address(market), true, uint128(100 * USDC), uint128(50 * MON), 0);
    }

    function test_M4_globalPauseStopsTrading() public {
        (bytes32 id, address vault) = _register(address(0));
        _allowMarket(id);
        vm.prank(authority);
        custos.pause();
        vm.prank(agentWallet);
        vm.expectRevert(Paused.selector);
        AgentVault(vault).executeSwap(address(market), true, uint128(100 * USDC), 0, 0);
        vm.prank(authority);
        custos.unpause();
        vm.prank(agentWallet);
        AgentVault(vault).executeSwap(address(market), true, uint128(100 * USDC), 0, 0);
    }

    /* ------------------------------ L1 / L5 / L7 --------------------------- */

    function test_L1_zeroSeedRejectedEvenWithZeroMinSeed() public {
        vm.prank(authority);
        custos.setMinSeed(0);
        vm.prank(alice);
        vm.expectRevert(SeedTooSmall.selector);
        custos.registerAgent(bytes32("x"), "", agentWallet, 0, 0, 0, 0, address(0), 5000, true, 0);
    }

    function test_L5_depositToAgentRejected() public {
        (, address vault) = _register(address(0));
        usdc.mint(bob, 100 * USDC);
        vm.startPrank(bob);
        usdc.approve(vault, type(uint256).max);
        vm.expectRevert(AgentCannotCallThis.selector);
        AgentVault(vault).deposit(100 * USDC, agentWallet);
        vm.expectRevert(AgentCannotCallThis.selector);
        AgentVault(vault).mint(100 * USDC, agentWallet);
        vm.stopPrank();
    }

    function test_L7_transferUpgradeAuthority() public {
        address next = makeAddr("nextAuthority");
        vm.prank(authority);
        custos.transferUpgradeAuthority(next);
        assertEq(custos.upgradeAuthority(), next);
        vm.prank(authority);
        vm.expectRevert(NotUpgradeAuthority.selector);
        custos.setMinSeed(1);
        vm.prank(next);
        custos.setMinSeed(1);
    }
}
