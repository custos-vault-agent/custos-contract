// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {DeploymentFile} from "./DeploymentFile.sol";

import {CustosCore} from "../src/CustosCore.sol";
import {VaultFactory} from "../src/VaultFactory.sol";

/// @notice Deploys a fresh VaultFactory and points the proxy at it. AgentVault's code
///         lives in the factory, so a change to the vault needs this, not an upgrade of
///         CustosCore. Vaults that already exist keep the code they were deployed with.
contract UpgradeFactoryScript is DeploymentFile {
    using stdJson for string;

    function run() external {
        uint256 upgradeAuthorityKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        address proxy = vm.readFile(_file()).readAddress(".custosProxy");

        vm.startBroadcast(upgradeAuthorityKey);
        VaultFactory factory = new VaultFactory(proxy);
        CustosCore(proxy).setVaultFactory(address(factory));
        vm.stopBroadcast();

        _put("vaultFactory", address(factory));
        console2.log("New VaultFactory", address(factory));
    }
}
