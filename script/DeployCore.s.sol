// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeploymentFile} from "./DeploymentFile.sol";
import {CustosCore} from "../src/CustosCore.sol";
import {CustosProxy} from "../src/CustosProxy.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {NansenModule} from "../src/modules/NansenModule.sol";

/// @notice `make deployCore` — CustosCore (UUPS proxy), NansenModule (UUPS proxy),
///         VaultFactory, PriceOracle. Belum dikonfigurasi: jalankan `make init`
///         sesudahnya, kalau tidak `registerAgent` revert.
contract DeployCoreScript is DeploymentFile {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address usdc = _must("USDC_ADDRESS", "usdc");
        address attestor = vm.envOr("ATTESTOR_ADDRESS", deployer);

        vm.startBroadcast(deployerKey);

        address implementation = address(new CustosCore());
        CustosCore custos = CustosCore(
            address(new CustosProxy(implementation, abi.encodeCall(CustosCore.initialize, (deployer, usdc))))
        );

        address nansenImplementation = address(new NansenModule());
        NansenModule nansen = NansenModule(
            address(
                new CustosProxy(
                    nansenImplementation,
                    abi.encodeCall(NansenModule.initialize, (deployer, attestor, address(custos)))
                )
            )
        );

        VaultFactory vaultFactory = new VaultFactory(address(custos));
        PriceOracle priceOracle = new PriceOracle(deployer, usdc);

        vm.stopBroadcast();

        _put("usdc", usdc);
        _put("custosProxy", address(custos));
        _put("custosImplementation", implementation);
        _put("nansenModule", address(nansen));
        _put("nansenModuleImplementation", nansenImplementation);
        _put("vaultFactory", address(vaultFactory));
        _put("priceOracle", address(priceOracle));
    }
}
