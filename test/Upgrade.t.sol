// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {CustosLogic} from "../src/CustosLogic.sol";
import {Agent, Status} from "../src/Types.sol";
import {NotUpgradeAuthority} from "../src/Errors.sol";
import {CustosLogicV2} from "./mocks/CustosLogicV2.sol";

contract UpgradeTest is Base {
    /// @notice Klaim yang seluruh arsitektur ini dibangun untuk membuktikan: upgrade
    ///         tidak menyentuh state. Namespace ERC-7201 membuat penambahan modul tidak
    ///         bisa menggeser satu pun field, jadi tidak ada migrasi dan tidak ada saldo
    ///         yang perlu dipindahkan.
    function test_upgradePreservesState() public {
        _deposit(alice, usdc, 1_000 * USDC);
        _deposit(alice, mon, 5 * MON);
        bytes32 id = _registerAgent(alice, agentWallet, uint128(600 * USDC), 30 days);

        vm.prank(agentWallet);
        custos.executeSwap(address(market), true, uint128(200 * USDC), 0, 0);

        Agent memory before = custos.getAgent(id);
        uint256 usdcBefore = custos.balanceOf(alice, address(usdc));
        uint256 monBefore = custos.balanceOf(alice, address(mon));
        uint256 availableBefore = custos.availableOf(alice);

        address v2 = address(new CustosLogicV2());
        vm.prank(authority);
        custos.upgradeToAndCall(v2, "");

        assertEq(CustosLogicV2(address(custos)).version(), "2.0.0");

        Agent memory afterUpgrade = custos.getAgent(id);
        assertEq(afterUpgrade.owner, before.owner);
        assertEq(afterUpgrade.wallet, before.wallet);
        assertEq(afterUpgrade.allowance, before.allowance);
        assertEq(afterUpgrade.usedInPeriod, before.usedInPeriod);
        assertEq(afterUpgrade.periodStart, before.periodStart);
        assertEq(afterUpgrade.periodLength, before.periodLength);
        assertEq(uint8(afterUpgrade.status), uint8(before.status));

        assertEq(custos.balanceOf(alice, address(usdc)), usdcBefore);
        assertEq(custos.balanceOf(alice, address(mon)), monBefore);
        assertEq(custos.availableOf(alice), availableBefore);

        // Konfigurasi ikut selamat, dan fungsi baru membaca record lama apa adanya.
        assertEq(custos.auroraReceiver(), receiver);
        assertEq(custos.accountingAsset(), address(usdc));
        assertEq(CustosLogicV2(address(custos)).agentOwnerOf(id), alice);
    }

    /// @notice Trading harus tetap berjalan mulus lintas upgrade — bukan sekadar terbaca.
    function test_tradingContinuesAfterUpgrade() public {
        _deposit(alice, usdc, 1_000 * USDC);
        bytes32 id = _registerAgent(alice, agentWallet, uint128(600 * USDC), 30 days);

        address v2 = address(new CustosLogicV2());
        vm.prank(authority);
        custos.upgradeToAndCall(v2, "");

        vm.prank(agentWallet);
        custos.executeSwap(address(market), true, uint128(300 * USDC), 0, 0);

        assertEq(custos.getAgent(id).usedInPeriod, 300 * USDC);
        assertEq(custos.balanceOf(alice, address(mon)), 150 * MON);
    }

    function test_upgradeOnlyByAuthority() public {
        address v2 = address(new CustosLogicV2());

        vm.prank(alice);
        vm.expectRevert(NotUpgradeAuthority.selector);
        custos.upgradeToAndCall(v2, "");
    }

    /// @notice Implementation yang bisa di-initialize orang lain berarti ia bisa
    ///         di-upgrade ke kontrak ber-`selfdestruct`, dan proxy ikut mati.
    function test_implementationCannotBeInitialized() public {
        vm.expectRevert();
        CustosLogic(implementation).initialize(alice, address(usdc));
    }

    function test_cannotInitializeTwice() public {
        vm.expectRevert();
        custos.initialize(alice, address(usdc));
    }
}
