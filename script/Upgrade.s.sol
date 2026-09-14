// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {CustosCore} from "../src/CustosCore.sol";

/// @notice Deploys a new CustosCore implementation and upgrades the existing
///         proxy to it (UUPS). Reads/updates deployments/anvil.json so there
///         is one source of truth for addresses, same as Deploy.s.sol.
contract UpgradeScript is Script {
    using stdJson for string;

    function run() external {
        uint256 upgradeAuthorityKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        string memory existing = vm.readFile("deployments/anvil.json");
        address proxy = existing.readAddress(".custosProxy");

        vm.startBroadcast(upgradeAuthorityKey);
        address newImplementation = address(new CustosCore());
        CustosCore(proxy).upgradeToAndCall(newImplementation, "");
        vm.stopBroadcast();

        vm.writeJson(vm.toString(newImplementation), "deployments/anvil.json", ".custosImplementation");

        console2.log("Upgraded proxy", proxy);
        console2.log("New implementation", newImplementation);
    }
}
