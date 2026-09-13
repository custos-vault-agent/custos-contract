// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {CustosLogic} from "../../src/CustosLogic.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMarket} from "../mocks/MockMarket.sol";

/// @notice Menggerakkan Custos lewat urutan aksi acak. Reverts diabaikan
///         (`fail_on_revert = false`): yang diuji bukan apakah setiap panggilan sukses,
///         melainkan apakah invarian tetap berlaku setelah urutan apa pun yang sukses.
contract Handler is CommonBase, StdCheats, StdUtils {
    CustosLogic public immutable custos;
    MockERC20 public immutable usdc;
    MockERC20 public immutable mon;
    MockMarket public immutable market;
    address public immutable receiver;

    address[3] public owners;
    address[6] public wallets;
    bytes32[] public ids;

    constructor(
        CustosLogic custos_,
        MockERC20 usdc_,
        MockERC20 mon_,
        MockMarket market_,
        address receiver_
    ) {
        custos = custos_;
        usdc = usdc_;
        mon = mon_;
        market = market_;
        receiver = receiver_;

        owners = [makeAddr("o0"), makeAddr("o1"), makeAddr("o2")];
        for (uint256 i = 0; i < 6; i++) {
            wallets[i] = makeAddr(string(abi.encodePacked("w", vm.toString(i))));
        }
    }

    /* ------------------------------ helpers ------------------------------ */

    function ownerCount() external pure returns (uint256) {
        return 3;
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function _owner(uint256 seed) internal view returns (address) {
        return owners[seed % 3];
    }

    function _token(bool useMon) internal view returns (MockERC20) {
        return useMon ? mon : usdc;
    }

    /* ------------------------------- aksi -------------------------------- */

    function deposit(uint256 ownerSeed, uint256 amount, bool useMon) external {
        MockERC20 token = _token(useMon);
        amount = bound(amount, 1, 1_000_000e6);
        token.mint(address(custos), amount);
        vm.prank(receiver);
        custos.creditDeposit(_owner(ownerSeed), address(token));
    }

    function withdraw(uint256 ownerSeed, uint256 amount, bool useMon) external {
        address owner = _owner(ownerSeed);
        MockERC20 token = _token(useMon);
        amount = bound(amount, 1, custos.balanceOf(owner, address(token)) + 1);
        vm.prank(owner);
        custos.withdraw(address(token), amount);
    }

    function register(uint256 ownerSeed, uint256 walletSeed, uint128 allowance, uint32 period)
        external
    {
        address owner = _owner(ownerSeed);
        allowance = uint128(bound(allowance, 0, 1_000_000e6));
        period = uint32(bound(period, 0, 90 days));

        vm.prank(owner);
        bytes32 id =
            custos.registerAgent(bytes32("bot"), "d", wallets[walletSeed % 6], allowance, period);
        ids.push(id);
    }

    function setAllowance(uint256 idSeed, uint128 allowance) external {
        if (ids.length == 0) return;
        bytes32 id = ids[idSeed % ids.length];
        allowance = uint128(bound(allowance, 0, 1_000_000e6));
        vm.prank(custos.getAgent(id).owner);
        custos.setAllowance(id, allowance);
    }

    function setPeriod(uint256 idSeed, uint32 period) external {
        if (ids.length == 0) return;
        bytes32 id = ids[idSeed % ids.length];
        vm.prank(custos.getAgent(id).owner);
        custos.setPeriod(id, uint32(bound(period, 0, 90 days)));
    }

    function pauseAgent(uint256 idSeed) external {
        if (ids.length == 0) return;
        bytes32 id = ids[idSeed % ids.length];
        vm.prank(custos.getAgent(id).owner);
        custos.pauseAgent(id);
    }

    function resumeAgent(uint256 idSeed) external {
        if (ids.length == 0) return;
        bytes32 id = ids[idSeed % ids.length];
        vm.prank(custos.getAgent(id).owner);
        custos.resumeAgent(id);
    }

    function revokeAgent(uint256 idSeed) external {
        if (ids.length == 0) return;
        bytes32 id = ids[idSeed % ids.length];
        vm.prank(custos.getAgent(id).owner);
        custos.revokeAgent(id);
    }

    /// @dev Pemanggil bisa seorang owner atau sebuah wallet agent — persis ambiguitas
    ///      yang `_resolveActor` harus selesaikan dengan benar setiap kali.
    ///
    ///      `amountIn` diikat ke saldo yang benar-benar dimiliki pihak yang akan
    ///      terkena beban, supaya sebagian besar panggilan benar-benar tereksekusi.
    ///      Tanpa ini hampir semua swap acak mental di `InsufficientBalance` dan jalur
    ///      trading nyaris tidak pernah tersentuh — mesin fuzz jadi terlihat sibuk
    ///      sambil tidak menguji apa pun.
    function swap(uint256 callerSeed, bool isBuy, uint128 amountIn, uint128 maxNotional) external {
        address caller = callerSeed % 2 == 0 ? owners[callerSeed % 3] : wallets[callerSeed % 6];
        (address account, bool viaAgent) = _chargedAccount(caller);

        // Buy oleh owner langsung dibatasi `available`, bukan saldo penuh; lewat agent,
        // pengurangan saldo selalu terimbangi allowance sehingga saldo penuh yang berlaku.
        uint256 cap = isBuy
            ? (viaAgent ? custos.balanceOf(account, address(usdc)) : custos.availableOf(account))
            : custos.balanceOf(account, address(mon));
        if (cap == 0) return;
        amountIn = uint128(bound(amountIn, 1, cap));
        maxNotional = uint128(bound(maxNotional, 0, 1_000_000e6));

        vm.prank(caller);
        custos.executeSwap(address(market), isBuy, amountIn, 0, maxNotional);
    }

    /// @dev Cermin dari `_resolveActor` di sisi test: wallet agent membelanjakan saldo
    ///      owner-nya, bukan saldonya sendiri.
    function _chargedAccount(address caller) internal view returns (address, bool) {
        bytes32 id = custos.agentIdOf(caller);
        if (id == bytes32(0)) return (caller, false);
        return (custos.getAgent(id).owner, true);
    }

    /// @dev Waktu harus ikut bergerak: reset periode adalah satu-satunya cara state
    ///      berubah tanpa transaksi, dan justru di sanalah akuntansi paling rapuh.
    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 45 days));
    }

    function movePrice(uint256 num) external {
        market.setPrice(bound(num, 1e5, 1e8), 1e18);
    }

    function setSpendBps(uint256 bps) external {
        market.setSpendBps(bound(bps, 1, 10_000));
    }
}
