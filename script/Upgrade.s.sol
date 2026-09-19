// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {DeploymentFile} from "./DeploymentFile.sol";

import {CustosCore} from "../src/CustosCore.sol";
import {NansenModule} from "../src/modules/NansenModule.sol";

/// @notice Deploys a fresh implementation and upgrades the matching proxy
///         (UUPS) — CustosCore by default, or NansenModule via
///         UPGRADE_TARGET=nansen. Reads/updates DEPLOYMENT_FILE so
///         there is one source of truth for addresses, same as Deploy.s.sol.
contract UpgradeScript is DeploymentFile {
    using stdJson for string;

    function run() external {
        uint256 upgradeAuthorityKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        string memory target = vm.envOr("UPGRADE_TARGET", string("core"));

        string memory existing = vm.readFile(_file());

        if (keccak256(bytes(target)) == keccak256(bytes("nansen"))) {
            address proxy = existing.readAddress(".nansenModule");

            vm.startBroadcast(upgradeAuthorityKey);
            address newImplementation = address(new NansenModule());
            NansenModule(proxy).upgradeToAndCall(newImplementation, "");
            vm.stopBroadcast();

            _put("nansenModuleImplementation", newImplementation);
            console2.log("Upgraded NansenModule proxy", proxy);
            console2.log("New implementation", newImplementation);
        } else {
            address proxy = existing.readAddress(".custosProxy");

            vm.startBroadcast(upgradeAuthorityKey);
            address newImplementation = address(new CustosCore());
            CustosCore(proxy).upgradeToAndCall(newImplementation, "");
            vm.stopBroadcast();

            _put("custosImplementation", newImplementation);
            console2.log("Upgraded CustosCore proxy", proxy);
            console2.log("New implementation", newImplementation);
        }
    }
}
