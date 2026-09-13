// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {CustosLogic} from "../../src/CustosLogic.sol";
import {CustosProxy} from "../../src/CustosProxy.sol";
import {Agent, Status} from "../../src/Types.sol";
import {Handler} from "./Handler.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMarket} from "../mocks/MockMarket.sol";

/// @notice Invarian I1–I5 dan I7 dari spec, diuji terhadap urutan aksi acak.
contract CustosInvariantTest is Test {
    CustosLogic internal custos;
    MockERC20 internal usdc;
    MockERC20 internal mon;
    MockMarket internal market;
    Handler internal handler;

    address internal authority = makeAddr("authority");
    address internal receiver = makeAddr("receiver");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        mon = new MockERC20("Monad", "MON", 18);

        custos = CustosLogic(
            address(
                new CustosProxy(
                    address(new CustosLogic()),
                    abi.encodeCall(CustosLogic.initialize, (authority, address(usdc)))
                )
            )
        );

        market = new MockMarket(address(mon), address(usdc), 2e6, 1e18);
        mon.mint(address(market), 1e30);
        usdc.mint(address(market), 1e30);

        vm.startPrank(authority);
        custos.setAuroraReceiver(receiver);
        custos.setMarketAllowed(address(market), true);
        vm.stopPrank();

        handler = new Handler(custos, usdc, mon, market, receiver);
        targetContract(address(handler));
    }

    /* ---------------------------------------------------------------------- */

    /// @notice I1 — buku besar cocok dengan yang dilacak, dan tidak pernah melebihi
    ///         token yang benar-benar dipegang kontrak.
    function invariant_ledgerIsBacked() public view {
        address[2] memory tokens = [address(usdc), address(mon)];
        for (uint256 t = 0; t < 2; t++) {
            uint256 sum;
            for (uint256 i = 0; i < 3; i++) {
                sum += custos.balanceOf(handler.owners(i), tokens[t]);
            }
            for (uint256 i = 0; i < 6; i++) {
                sum += custos.balanceOf(handler.wallets(i), tokens[t]);
            }
            assertEq(sum, custos.totalTracked(tokens[t]), "I1: jumlah saldo != totalTracked");
            assertLe(
                custos.totalTracked(tokens[t]),
                MockERC20(tokens[t]).balanceOf(address(custos)),
                "I1: buku besar melebihi token yang dipegang"
            );
        }
    }

    /// @notice I2 — delegasi yang dilaporkan sama dengan jumlah sisa allowance agent
    ///         hidup. Yang benar-benar diuji di sini adalah pemeliharaan daftar
    ///         `agentsOfOwner`: sebuah id yang lolos dari penghapusan saat revoke akan
    ///         langsung terlihat.
    function invariant_delegationMatchesAgents() public view {
        for (uint256 i = 0; i < 3; i++) {
            address owner = handler.owners(i);
            bytes32[] memory agentIds = custos.agentsOfOwner(owner);
            uint256 sum;
            for (uint256 j = 0; j < agentIds.length; j++) {
                sum += custos.remainingOf(agentIds[j]);
            }
            assertEq(sum, custos.delegatedOf(owner), "I2");
        }
    }

    /// @notice I3 — janji `available`: saldo aset akuntansi selalu menutupi delegasi.
    ///         Kalau ini jatuh, seorang owner berhasil menarik dana yang masih
    ///         tercadang untuk agent-nya.
    function invariant_balanceCoversDelegation() public view {
        for (uint256 i = 0; i < 3; i++) {
            address owner = handler.owners(i);
            assertGe(
                custos.balanceOf(owner, address(usdc)),
                custos.delegatedOf(owner),
                "I3: delegasi melebihi saldo"
            );
        }
    }

    /// @notice I4 dan I5 — headroom tidak pernah melampaui allowance, dan `reserved`
    ///         tetap nol sepanjang MVP.
    ///
    /// @dev Dinyatakan lewat `remainingOf`, bukan `usedInPeriod <= allowance`. Bentuk
    ///      kedua itu salah: seorang owner boleh menurunkan allowance ke bawah pemakaian
    ///      yang sudah tercatat — justru itulah cara ia menghentikan agent seketika — dan
    ///      state `used > allowance` yang muncul karenanya sah sepenuhnya. Yang harus
    ///      selalu benar adalah headroom-nya nol di situ, dan itu yang diuji di sini
    ///      bersama `test_loweringAllowanceBelowUsageStopsAgent`.
    function invariant_usageWithinAllowance() public view {
        uint256 n = custos.agentCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = custos.agentAt(i);
            Agent memory a = custos.getAgent(id);
            assertEq(a.reserved, 0, "I5: reserved harus nol di MVP");
            assertLe(custos.remainingOf(id), a.allowance, "I4: headroom melebihi allowance");
            if (a.status == Status.Active && a.usedInPeriod >= a.allowance) {
                assertEq(custos.remainingOf(id), 0, "I4: headroom tersisa padahal kuota habis");
            }
        }
    }

    /// @notice I7 — agent yang di-pause atau dicabut tidak menahan dana sedikit pun.
    function invariant_inactiveAgentsHoldNothing() public view {
        uint256 n = custos.agentCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = custos.agentAt(i);
            if (custos.getAgent(id).status != Status.Active) {
                assertEq(custos.remainingOf(id), 0, "I7");
            }
        }
    }

    /// @notice I8 — ikatan wallet 1:1 dan permanen. Sebuah wallet yang bisa dipetakan
    ///         ulang berarti agent yang dicabut bisa hidup kembali.
    function invariant_walletBindingIsStable() public view {
        uint256 n = custos.agentCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = custos.agentAt(i);
            Agent memory a = custos.getAgent(id);
            assertEq(custos.agentIdOf(a.wallet), id, "I8: ikatan wallet bergeser");
        }
    }
}
