// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @notice Satu file JSON (`DEPLOYMENT_FILE`, default deployments/anvil.json) yang
///         dibagi DeployMock / DeployCore / Init / Upgrade. Tiap script hanya
///         meng-upsert key miliknya, jadi urutan dan pengulangan bebas.
abstract contract DeploymentFile is Script {
    using stdJson for string;

    function _file() internal view returns (string memory) {
        return vm.envOr("DEPLOYMENT_FILE", string("deployments/anvil.json"));
    }

    function _put(string memory key, address value) internal {
        string memory path = _file();
        if (!vm.exists(path)) vm.writeFile(path, "{}");
        vm.writeJson(vm.toString(value), path, string.concat(".", key));
    }

    /// @dev `ENV` dulu, lalu `.key` di file, lalu address(0).
    function _addr(string memory env, string memory key) internal view returns (address) {
        address a = vm.envOr(env, address(0));
        if (a != address(0)) return a;
        string memory path = _file();
        if (!vm.exists(path)) return address(0);
        string memory json = vm.readFile(path);
        if (!json.keyExists(string.concat(".", key))) return address(0);
        return json.readAddress(string.concat(".", key));
    }

    function _must(string memory env, string memory key) internal view returns (address a) {
        a = _addr(env, key);
        require(a != address(0), string.concat("missing ", env, " (env) or .", key, " in ", _file()));
    }
}
