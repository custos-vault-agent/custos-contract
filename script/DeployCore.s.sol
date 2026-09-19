// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeploymentFile} from "./DeploymentFile.sol";
import {CustosCore} from "../src/CustosCore.sol";
import {CustosProxy} from "../src/CustosProxy.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {NanSigil} from "nansigil-contract/NanSigil.sol";
import {NanSigilProxy} from "nansigil-contract/NanSigilProxy.sol";

/// @notice `make deployCore` — CustosCore (UUPS proxy), NanSigil (UUPS proxy, unless
///         NANSIGIL_ADDRESS / .nansigil already points at one),
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

        // NanSigil is its own product with its own repo; deploy it here only when no
        // address is given, so a shared instance can be reused across consumers.
        address nansigil = _addr("NANSIGIL_ADDRESS", "nansigil");
        if (nansigil == address(0)) {
            address nansigilImplementation = address(new NanSigil());
            nansigil = address(
                new NanSigilProxy(
                    nansigilImplementation, abi.encodeCall(NanSigil.initialize, (deployer, attestor))
                )
            );
            _put("nansigilImplementation", nansigilImplementation);
        }

        VaultFactory vaultFactory = new VaultFactory(address(custos));
        PriceOracle priceOracle = new PriceOracle(deployer, usdc);

        vm.stopBroadcast();

        _put("usdc", usdc);
        _put("custosProxy", address(custos));
        _put("custosImplementation", implementation);
        _put("nansigil", nansigil);
        _put("vaultFactory", address(vaultFactory));
        _put("priceOracle", address(priceOracle));
    }
}
