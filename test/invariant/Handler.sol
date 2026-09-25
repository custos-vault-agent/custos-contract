// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {AgentVault} from "../../src/AgentVault.sol";
import {CustosCore} from "../../src/CustosCore.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMarket} from "../mocks/MockMarket.sol";

/// @notice Menggerakkan CustosCore + N AgentVault independen lewat urutan aksi acak.
///         Reverts diabaikan (`fail_on_revert = false`) — yang diuji adalah invarian
///         setelah urutan yang berhasil, bukan apakah setiap panggilan lolos.
contract Handler is CommonBase, StdCheats, StdUtils {
    CustosCore public immutable custos;
    MockERC20 public immutable usdc;
    MockERC20 public immutable mon;
    MockMarket public immutable market;
    address public immutable authority;

    address[3] public creators;
    address[3] public agentWallets;
    address[3] public subscribers;
    bytes32[] public ids;

    /// @dev Floor yang naik seiring waktu, dan hanya "diturunkan" (ke nilai baru
    ///      yang sah) tepat saat `resumeAgent` benar-benar dipanggil — cermin dari
    ///      satu-satunya pengecualian I2 di spec.
    mapping(bytes32 id => uint256 floor) public hwmFloor;
    /// @dev Jumlah share di `address(1)` tepat setelah seed — I4 menegaskan angka
    ///      ini tidak pernah turun.
    mapping(bytes32 id => uint256 shares) public seedShares;

    constructor(CustosCore custos_, MockERC20 usdc_, MockERC20 mon_, MockMarket market_, address authority_) {
        custos = custos_;
        usdc = usdc_;
        mon = mon_;
        market = market_;
        authority = authority_;

        creators = [makeAddr("c0"), makeAddr("c1"), makeAddr("c2")];
        agentWallets = [makeAddr("w0"), makeAddr("w1"), makeAddr("w2")];
        subscribers = [makeAddr("s0"), makeAddr("s1"), makeAddr("s2")];
    }

    /* ------------------------------ helpers ------------------------------ */

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function _vaultOf(bytes32 id) internal view returns (address) {
        return custos.getAgent(id).vault;
    }

    function _walletOf(bytes32 id) internal view returns (address) {
        return custos.getAgent(id).wallet;
    }

    function _creatorOf(bytes32 id) internal view returns (address) {
        return custos.getAgent(id).creator;
    }

    /* ------------------------------- aksi -------------------------------- */

    function register(
        uint256 creatorSeed,
        uint256 walletSeed,
        uint128 allowance,
        uint32 period,
        uint16 feeRate,
        uint16 drawdown,
        uint16 util,
        uint128 seedAmount
    ) external {
        address creator = creators[creatorSeed % 3];
        address wallet = agentWallets[walletSeed % 3];
        allowance = uint128(bound(allowance, 0, 1_000_000e6));
        period = uint32(bound(period, 0, 90 days));
        feeRate = uint16(bound(feeRate, 0, 5000));
        drawdown = uint16(bound(drawdown, 0, 5000));
        util = uint16(bound(util, 1000, 9500));
        seedAmount = uint128(bound(seedAmount, 500e6, 100_000e6));

        usdc.mint(creator, seedAmount);
        vm.prank(creator);
        usdc.approve(address(custos), seedAmount);

        vm.prank(creator);
        (bytes32 id, address vault) = custos.registerAgent(
            bytes32("bot"),
            "d",
            wallet,
            allowance,
            period,
            feeRate,
            drawdown,
            address(0),
            util,
            true,
            seedAmount
        );
        ids.push(id);
        hwmFloor[id] = 1e18;
        seedShares[id] = AgentVault(vault).balanceOf(address(1));

        vm.prank(authority);
        custos.setMarketAllowed(id, address(market), true);
    }

    function subscribe(uint256 idSeed, uint256 subSeed, uint256 amount) external {
        if (ids.length == 0) return;
        bytes32 id = ids[idSeed % ids.length];
        address subscriber = subscribers[subSeed % 3];
        amount = bound(amount, 1, 1_000_000e6);

        usdc.mint(subscriber, amount);
        vm.prank(subscriber);
        usdc.approve(_vaultOf(id), amount);
        vm.prank(subscriber);
        AgentVault(_vaultOf(id)).deposit(amount, subscriber);
    }

    function redeem(uint256 idSeed, uint256 subSeed, uint256 shares) external {
        if (ids.length == 0) return;
        bytes32 id = ids[idSeed % ids.length];
        address subscriber = subscribers[subSeed % 3];
        AgentVault vault = AgentVault(_vaultOf(id));
        uint256 bal = vault.balanceOf(subscriber);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);

        vm.prank(subscriber);
        vault.redeem(shares, subscriber, subscriber);
    }

    function swap(uint256 idSeed, bool isBuy, uint128 amountIn, uint128 maxNotional) external {
        if (ids.length == 0) return;
        bytes32 id = ids[idSeed % ids.length];
        AgentVault vault = AgentVault(_vaultOf(id));

        uint256 cap = isBuy ? vault.totalAssets() : mon.balanceOf(address(vault));
        if (cap == 0) return;
        amountIn = uint128(bound(amountIn, 1, cap));
        maxNotional = uint128(bound(maxNotional, 0, 1_000_000e6));

        vm.prank(_walletOf(id));
        vault.executeSwap(address(market), isBuy, amountIn, 0, maxNotional);
    }

    function pauseAgent(uint256 idSeed) external {
        if (ids.length == 0) return;
        bytes32 id = ids[idSeed % ids.length];
        vm.prank(_creatorOf(id));
        custos.pauseAgent(id);
    }

    function resumeAgent(uint256 idSeed) external {
        if (ids.length == 0) return;
        bytes32 id = ids[idSeed % ids.length];
        vm.prank(_creatorOf(id));
        custos.resumeAgent(id);
        hwmFloor[id] = AgentVault(_vaultOf(id)).highWaterMark();
    }

    function revokeAgent(uint256 idSeed) external {
        if (ids.length == 0) return;
        bytes32 id = ids[idSeed % ids.length];
        vm.prank(_creatorOf(id));
        custos.revokeAgent(id);
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 45 days));
    }

    function movePrice(uint256 num) external {
        market.setPrice(bound(num, 1e5, 1e8), 1e18);
    }
}
