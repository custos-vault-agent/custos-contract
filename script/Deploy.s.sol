// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {CustosCore} from "../src/CustosCore.sol";
import {CustosProxy} from "../src/CustosProxy.sol";
import {MockYieldSource} from "../src/adapters/MockYieldSource.sol";
import {FixedPriceMarket} from "../src/adapters/FixedPriceMarket.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Deploys the full Custos stack to a local Anvil node. See
///         custos-web/docs/superpowers/specs/2026-09-14-wire-frontend-to-
///         contracts-design.md (section A) for the full rationale.
contract DeployScript is Script {
    uint256 internal constant USDC = 1e6;
    uint256 internal constant MON = 1e18;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 mon = new MockERC20("Monad", "MON", 18);

        address implementation = address(new CustosCore());
        CustosCore custos = CustosCore(
            address(
                new CustosProxy(
                    implementation, abi.encodeCall(CustosCore.initialize, (deployer, address(usdc)))
                )
            )
        );

        // 1 MON = 2 USDC, same convention as test/Base.t.sol.
        FixedPriceMarket market = new FixedPriceMarket(address(mon), address(usdc), 2 * USDC, 1 * MON);
        mon.mint(address(market), 1_000_000 * MON);
        usdc.mint(address(market), 1_000_000 * USDC);

        MockYieldSource yieldSource = new MockYieldSource(address(usdc), 500); // 5% APY

        custos.setMarketAdapter(address(market));
        custos.setMinSeed(uint128(500 * USDC));
        custos.setAttestor(deployer);

        vm.stopBroadcast();

        string memory json = "deployment";
        vm.serializeAddress(json, "custosProxy", address(custos));
        vm.serializeAddress(json, "custosImplementation", implementation);
        vm.serializeAddress(json, "usdc", address(usdc));
        vm.serializeAddress(json, "mon", address(mon));
        vm.serializeAddress(json, "market", address(market));
        string memory finalJson = vm.serializeAddress(json, "yieldSource", address(yieldSource));
        vm.writeJson(finalJson, "deployments/anvil.json");

        console2.log("Custos proxy deployed at", address(custos));
    }
}
