// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {CustosCore} from "../src/CustosCore.sol";
import {NansenModule} from "../src/modules/NansenModule.sol";

/// @notice Deploys a fresh implementation and upgrades the matching proxy
///         (UUPS) — CustosCore by default, or NansenModule via
///         UPGRADE_TARGET=nansen. Reads/updates deployments/anvil.json so
///         there is one source of truth for addresses, same as Deploy.s.sol.
contract UpgradeScript is Script {
    using stdJson for string;

    function run() external {
        uint256 upgradeAuthorityKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        string memory target = vm.envOr("UPGRADE_TARGET", string("core"));

        string memory existing = vm.readFile("deployments/anvil.json");

        if (keccak256(bytes(target)) == keccak256(bytes("nansen"))) {
            address proxy = existing.readAddress(".nansenModule");

            vm.startBroadcast(upgradeAuthorityKey);
            address newImplementation = address(new NansenModule());
            NansenModule(proxy).upgradeToAndCall(newImplementation, "");
            vm.stopBroadcast();

            vm.writeJson(vm.toString(newImplementation), "deployments/anvil.json", ".nansenModuleImplementation");
            console2.log("Upgraded NansenModule proxy", proxy);
            console2.log("New implementation", newImplementation);
        } else {
            address proxy = existing.readAddress(".custosProxy");

            vm.startBroadcast(upgradeAuthorityKey);
            address newImplementation = address(new CustosCore());
            CustosCore(proxy).upgradeToAndCall(newImplementation, "");
            vm.stopBroadcast();

            vm.writeJson(vm.toString(newImplementation), "deployments/anvil.json", ".custosImplementation");
            console2.log("Upgraded CustosCore proxy", proxy);
            console2.log("New implementation", newImplementation);
        }
    }
}
