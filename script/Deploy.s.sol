// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {AgentVault} from "../src/AgentVault.sol";
import {CustosCore} from "../src/CustosCore.sol";
import {CustosProxy} from "../src/CustosProxy.sol";
import {MockYieldSource} from "../src/adapters/MockYieldSource.sol";
import {FixedPriceMarket} from "../src/adapters/FixedPriceMarket.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Deploys the full Custos stack to a local Anvil node and seeds it
///         with real demo agents, swaps, deposits, and Nansen attestations —
///         so the marketplace has genuine on-chain history instead of
///         fabricated numbers. See custos-web/docs/superpowers/specs/
///         2026-09-14-wire-frontend-to-contracts-design.md (section A).
contract DeployScript is Script {
    uint256 internal constant USDC = 1e6;
    uint256 internal constant MON = 1e18;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 demoUserKey = vm.envUint("DEMO_USER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address demoUser = vm.addr(demoUserKey);

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

        // Demo agent wallets are script-derived, not real secrets — fund
        // them with just enough ETH to pay gas for their seeded swaps.
        address[] memory agentWallets = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            agentWallets[i] = vm.addr(_agentKey(i));
            payable(agentWallets[i]).transfer(0.5 ether);
        }

        vm.stopBroadcast();

        // demoUser plays both creator and subscriber — one wallet is
        // enough to show every flow (ponytail: a hackathon demo doesn't
        // need more actors than that).
        vm.startBroadcast(demoUserKey);
        usdc.mint(demoUser, 50_000 * USDC);
        usdc.approve(address(custos), type(uint256).max);

        string[3] memory names = ["grid-bot-7", "arb-hunter", "mon-dca"];
        bytes32[] memory agentIds = new bytes32[](3);
        address[] memory vaults = new address[](3);

        for (uint256 i = 0; i < 3; i++) {
            (bytes32 id, address vault) = custos.registerAgent(
                bytes32(bytes(names[i])),
                "Seeded demo agent.",
                agentWallets[i],
                uint128(4_000 * USDC),
                1 days,
                1000, // feeRate 10%
                2000, // maxDrawdownBps 20%
                address(yieldSource),
                7000, // maxUtilizationBps 70%
                true,
                uint128(1_000 * USDC)
            );
            agentIds[i] = id;
            vaults[i] = vault;
        }
        vm.stopBroadcast();

        vm.startBroadcast(deployerKey);
        for (uint256 i = 0; i < 3; i++) {
            custos.setMarketAllowed(agentIds[i], address(market), true);
        }
        vm.stopBroadcast();

        // Real swaps move real share price — no invented numbers.
        //
        // totalAssets() only counts settled USDC (idle + yield) — an open
        // MON position is never marked to market — so a buy always reads
        // as an immediate drawdown of the full amount spent until it's
        // sold back. Both buys below stay under each vault's 20%
        // maxDrawdownBps so neither trips its circuit breaker.
        vm.startBroadcast(_agentKey(0));
        // 150 USDC of 1,000 USDC seed = 15% drop, under the 20% breaker.
        AgentVault(vaults[0]).executeSwap(address(market), true, uint128(150 * USDC), 0, 0);
        vm.stopBroadcast();

        vm.startBroadcast(_agentKey(1));
        // 120 USDC of 1,000 USDC seed = 12% drop. Left unsold on purpose —
        // an agent currently down on paper, same flavor as the old mock
        // data's underwater agents.
        AgentVault(vaults[1]).executeSwap(address(market), true, uint128(120 * USDC), 0, 0);
        vm.stopBroadcast();

        // MON rallies — agent 0 sells its 75 MON back into the rally,
        // realizing a real profit and minting a real FeeMinted event.
        vm.startBroadcast(deployerKey);
        market.setPrice(12 * USDC / 5, 1 * MON); // 2.4 USDC per MON
        vm.stopBroadcast();

        vm.startBroadcast(_agentKey(0));
        // 150 USDC / 2 USDC-per-MON = 75 MON received by the first buy.
        AgentVault(vaults[0]).executeSwap(address(market), false, uint128(75 * MON), 0, uint128(200 * USDC));
        vm.stopBroadcast();

        // A subscriber deposit on top of real trading activity.
        vm.startBroadcast(demoUserKey);
        usdc.approve(vaults[0], type(uint256).max);
        AgentVault(vaults[0]).deposit(2_000 * USDC, demoUser);
        vm.stopBroadcast();

        // Nansen: deployer acts as attestor (deferred live integration,
        // per the design spec). Plaintext lives in demo-nansen.json since
        // only the hash goes on-chain.
        bytes32[] memory nansenAgentIds = new bytes32[](2);
        address[] memory nansenWallets = new address[](2);
        string[] memory nansenLabels = new string[](2);
        int256[] memory nansenPnls = new int256[](2);
        uint256[] memory nansenWinRates = new uint256[](2);
        uint256[] memory nansenTimestamps = new uint256[](2);

        (
            nansenAgentIds[0],
            nansenWallets[0],
            nansenLabels[0],
            nansenPnls[0],
            nansenWinRates[0],
            nansenTimestamps[0]
        ) = _submitDemoAttestation(custos, deployerKey, demoUser, agentIds[0], "Smart Trader", 42_000, 61);
        (
            nansenAgentIds[1],
            nansenWallets[1],
            nansenLabels[1],
            nansenPnls[1],
            nansenWinRates[1],
            nansenTimestamps[1]
        ) = _submitDemoAttestation(custos, deployerKey, demoUser, agentIds[1], "Fund", 310_000, 58);

        string memory json = "deployment";
        vm.serializeAddress(json, "custosProxy", address(custos));
        vm.serializeAddress(json, "custosImplementation", implementation);
        vm.serializeAddress(json, "usdc", address(usdc));
        vm.serializeAddress(json, "mon", address(mon));
        vm.serializeAddress(json, "market", address(market));
        vm.serializeAddress(json, "yieldSource", address(yieldSource));
        vm.serializeBytes32(json, "agentIds", agentIds);
        vm.serializeAddress(json, "agentVaults", vaults);
        string memory finalJson = vm.serializeAddress(json, "agentWallets", agentWallets);
        vm.writeJson(finalJson, "deployments/anvil.json");

        string memory nansenJson = "nansen";
        vm.serializeBytes32(nansenJson, "agentIds", nansenAgentIds);
        vm.serializeAddress(nansenJson, "wallets", nansenWallets);
        vm.serializeString(nansenJson, "labels", nansenLabels);
        vm.serializeInt(nansenJson, "pnls", nansenPnls);
        vm.serializeUint(nansenJson, "winRates", nansenWinRates);
        string memory finalNansenJson = vm.serializeUint(nansenJson, "timestamps", nansenTimestamps);
        vm.writeJson(finalNansenJson, "deployments/demo-nansen.json");

        console2.log("Custos proxy deployed at", address(custos));
    }

    /// @dev Private key of a script-derived demo agent wallet — never a
    ///      real secret, only ever funded on local Anvil.
    function _agentKey(uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked("custos-demo-agent", i)));
    }

    function _submitDemoAttestation(
        CustosCore custos,
        uint256 attestorKey,
        address wallet,
        bytes32 agentId,
        string memory label,
        int256 pnl,
        uint256 winRate
    )
        internal
        returns (bytes32, address, string memory, int256, uint256, uint256)
    {
        uint256 timestamp = block.timestamp;
        bytes32 hash = keccak256(abi.encode(wallet, label, pnl, uint16(winRate), uint64(timestamp)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attestorKey, MessageHashUtils.toEthSignedMessageHash(hash));
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.startBroadcast(attestorKey);
        custos.submitAttestation(agentId, hash, signature);
        vm.stopBroadcast();

        return (agentId, wallet, label, pnl, winRate, timestamp);
    }
}
