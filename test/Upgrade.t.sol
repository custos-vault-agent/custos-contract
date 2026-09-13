// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {CustosCore} from "../src/CustosCore.sol";
import {AgentRecord} from "../src/Types.sol";
import {NotUpgradeAuthority} from "../src/Errors.sol";
import {CustosCoreV2} from "./mocks/CustosCoreV2.sol";

contract UpgradeTest is Base {
    function test_upgradePreservesRegistryAndVault() public {
        (bytes32 id, address vault) = _registerAgent(alice, agentWallet, uint128(4_000 * USDC), 1 days);

        AgentRecord memory before = custos.getAgent(id);
        uint256 vaultTotalAssetsBefore = AgentVault(vault).totalAssets();
        uint256 vaultSeedSharesBefore = AgentVault(vault).balanceOf(address(1));

        address v2 = address(new CustosCoreV2());
        vm.prank(authority);
        custos.upgradeToAndCall(v2, "");

        assertEq(CustosCoreV2(address(custos)).version(), "3.0.0");

        AgentRecord memory afterUpgrade = custos.getAgent(id);
        assertEq(afterUpgrade.creator, before.creator);
        assertEq(afterUpgrade.wallet, before.wallet);
        assertEq(afterUpgrade.vault, before.vault);
        assertEq(uint8(afterUpgrade.status), uint8(before.status));
        assertEq(CustosCoreV2(address(custos)).creatorOf(id), alice);

        // D13's actual claim: the vault address, its address(1)-locked seed shares,
        // and its totalAssets are completely untouched — not because nothing
        // *could* change, but because the vault was never a proxy to begin with and
        // CustosCore has no code path that reaches into it.
        assertEq(AgentVault(vault).totalAssets(), vaultTotalAssetsBefore);
        assertEq(AgentVault(vault).balanceOf(address(1)), vaultSeedSharesBefore);
    }

    /// @notice Trading harus tetap berjalan mulus lintas upgrade — bukan sekadar terbaca.
    function test_tradingContinuesAfterUpgrade() public {
        (bytes32 id, address vault) = _registerAgent(alice, agentWallet, uint128(4_000 * USDC), 1 days);
        _allowMarket(id);

        address v2 = address(new CustosCoreV2());
        vm.prank(authority);
        custos.upgradeToAndCall(v2, "");

        vm.prank(agentWallet);
        AgentVault(vault).executeSwap(address(market), true, uint128(500 * USDC), 0, 0);

        assertEq(AgentVault(vault).usedInPeriod(), 500 * USDC);
    }

    function test_upgradeOnlyByAuthority() public {
        address v2 = address(new CustosCoreV2());

        vm.prank(alice);
        vm.expectRevert(NotUpgradeAuthority.selector);
        custos.upgradeToAndCall(v2, "");
    }

    /// @notice Implementation yang bisa di-initialize orang lain berarti ia bisa
    ///         di-upgrade ke kontrak ber-`selfdestruct`, dan proxy ikut mati.
    function test_implementationCannotBeInitialized() public {
        vm.expectRevert();
        CustosCore(implementation).initialize(alice, address(usdc));
    }

    function test_cannotInitializeTwice() public {
        vm.expectRevert();
        custos.initialize(alice, address(usdc));
    }
}
