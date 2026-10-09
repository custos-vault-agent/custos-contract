// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {AgentVault} from "../src/AgentVault.sol";
import {CustosCore} from "../src/CustosCore.sol";
import {CustosProxy} from "../src/CustosProxy.sol";
import {MockYieldSource} from "../src/adapters/MockYieldSource.sol";
import {KuruMarketAdapter} from "../src/adapters/KuruMarketAdapter.sol";
import {IKuruRouter} from "../src/interfaces/IKuruRouter.sol";
import {NanSigil} from "nansigil-contract/NanSigil.sol";
import {NanSigilProxy} from "nansigil-contract/NanSigilProxy.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockAggregator} from "../test/mocks/MockAggregator.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockKuruFactory} from "../test/mocks/MockKuruFactory.sol";
import {MockKuruRouter} from "../test/mocks/MockKuruRouter.sol";

/// @notice Deploys the full Custos stack to a local Anvil node and seeds it
///         with real demo agents, swaps, deposits, and Nansen attestations —
///         so the marketplace has genuine on-chain history instead of
///         fabricated numbers. See custos-web/docs/superpowers/specs/
///         2026-09-14-wire-frontend-to-contracts-design.md (section A) and
///         docs/superpowers/specs/2026-09-14-nansen-module-split-design.md.
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

        // NanSigil: deployer is both upgrade authority and attestor for the demo.
        address nansigilImplementation = address(new NanSigil());
        NanSigil nansigil = NanSigil(
            address(
                new NanSigilProxy(
                    nansigilImplementation, abi.encodeCall(NanSigil.initialize, (deployer, deployer))
                )
            )
        );

        // Kuru path: factory registers the MON/USDC market — the same
        // "bring a new asset to Kuru" call shape the bounty targets — and the
        // adapter trades against it through the router, exactly like mainnet.
        // Mocked because neither has a usable testnet endpoint yet (see
        // IKuruFactory.sol / IKuruRouter.sol).
        MockKuruFactory kuruFactory = new MockKuruFactory();
        MockKuruRouter kuruRouter = new MockKuruRouter();
        address orderbook = kuruFactory.deployProxy(
            0, address(mon), address(usdc), 1e10, 1e2, 1, 1e6, type(uint96).max, 30, 10, 0
        );
        KuruMarketAdapter market =
            new KuruMarketAdapter(IKuruRouter(address(kuruRouter)), orderbook, address(0));

        // 1 MON = 2 USDC, same convention as test/Base.t.sol.
        kuruRouter.setPrice(orderbook, 2 * USDC, 1 * MON);
        mon.mint(address(kuruRouter), 1_000_000 * MON);
        usdc.mint(address(kuruRouter), 1_000_000 * USDC);

        MockYieldSource yieldSource = new MockYieldSource(address(usdc), 500); // 5% APY

        // H2: base token (MON) dinilai lewat Chainlink. Di Monad pakai proxy
        // MON/USD asli lewat MON_USD_FEED; di anvil tidak ada Chainlink, jadi
        // pakai mock dengan harga yang sama seperti router (2 USD).
        address monUsdFeed = vm.envOr("MON_USD_FEED", address(0));
        if (monUsdFeed == address(0)) monUsdFeed = address(new MockAggregator(8, 2e8));
        PriceOracle priceOracle = new PriceOracle(deployer, address(usdc));
        priceOracle.setFeed(address(mon), AggregatorV3Interface(monUsdFeed), 1 days);

        VaultFactory vaultFactory = new VaultFactory(address(custos));

        custos.setMarketAdapter(address(market));
        custos.setVaultFactory(address(vaultFactory));
        custos.setNanSigil(address(nansigil));
        custos.setPriceOracle(address(priceOracle));
        custos.setYieldSourceAllowed(address(yieldSource), true); // H1
        custos.setMinSeed(uint128(500 * USDC));

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
                uint128(1_000 * USDC),
                new address[](0)
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
        // totalAssets() marks the open MON position to the oracle price (H2),
        // so a buy at the oracle price is share-price neutral; only a later
        // price move changes it.
        vm.startBroadcast(_agentKey(0));
        AgentVault(vaults[0]).executeSwap(address(market), true, uint128(150 * USDC), 0, 0);
        vm.stopBroadcast();

        vm.startBroadcast(_agentKey(1));
        // Left unsold on purpose — an agent holding an open position.
        AgentVault(vaults[1]).executeSwap(address(market), true, uint128(120 * USDC), 0, 0);
        vm.stopBroadcast();

        // MON rallies — agent 0 sells its 75 MON back into the rally,
        // realizing a real profit and minting a real FeeMinted event.
        vm.startBroadcast(deployerKey);
        kuruRouter.setPrice(orderbook, 12 * USDC / 5, 1 * MON); // 2.4 USDC per MON
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

        // NanSigil: deployer signs one attestation for demoUser (the creator of every
        // demo agent). Plaintext is written to demo-nansen.json since only the hash
        // is stored on-chain; the event carries it too.
        uint64 attestedAt =
            _submitDemoAttestation(nansigil, deployerKey, demoUser, "Smart Trader", 42_000, 61);

        string memory json = "deployment";
        vm.serializeAddress(json, "custosProxy", address(custos));
        vm.serializeAddress(json, "custosImplementation", implementation);
        vm.serializeAddress(json, "nansigil", address(nansigil));
        vm.serializeAddress(json, "nansigilImplementation", nansigilImplementation);
        vm.serializeAddress(json, "usdc", address(usdc));
        vm.serializeAddress(json, "mon", address(mon));
        vm.serializeAddress(json, "market", address(market));
        vm.serializeAddress(json, "kuruOrderbook", orderbook);
        vm.serializeAddress(json, "kuruRouter", address(kuruRouter));
        vm.serializeAddress(json, "kuruFactory", address(kuruFactory));
        vm.serializeAddress(json, "yieldSource", address(yieldSource));
        vm.serializeAddress(json, "priceOracle", address(priceOracle));
        vm.serializeAddress(json, "vaultFactory", address(vaultFactory));
        vm.serializeAddress(json, "monUsdFeed", monUsdFeed);
        vm.serializeBytes32(json, "agentIds", agentIds);
        vm.serializeAddress(json, "agentVaults", vaults);
        string memory finalJson = vm.serializeAddress(json, "agentWallets", agentWallets);
        vm.writeJson(finalJson, "deployments/anvil.json");

        string memory nansenJson = "nansen";
        vm.serializeAddress(nansenJson, "wallet", demoUser);
        vm.serializeString(nansenJson, "label", "Smart Trader");
        vm.serializeInt(nansenJson, "pnl", int256(42_000));
        vm.serializeUint(nansenJson, "winRate", 61);
        string memory finalNansenJson = vm.serializeUint(nansenJson, "timestamp", attestedAt);
        vm.writeJson(finalNansenJson, "deployments/demo-nansen.json");

        console2.log("Custos proxy deployed at", address(custos));
        console2.log("NanSigil deployed at", address(nansigil));
    }

    /// @dev Private key of a script-derived demo agent wallet — never a
    ///      real secret, only ever funded on local Anvil.
    function _agentKey(uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked("custos-demo-agent", i)));
    }

    function _submitDemoAttestation(
        NanSigil nansigil,
        uint256 attestorKey,
        address wallet,
        string memory label,
        int256 pnl,
        uint16 winRate
    ) internal returns (uint64 timestamp) {
        timestamp = uint64(block.timestamp);
        bytes32 hash = keccak256(abi.encode(wallet, label, pnl, winRate, timestamp));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attestorKey, MessageHashUtils.toEthSignedMessageHash(hash));
        // Pull model: any relayer may submit; the demo reuses the deployer key.
        vm.startBroadcast(attestorKey);
        nansigil.submit(wallet, label, pnl, winRate, timestamp, abi.encodePacked(r, s, v));
        vm.stopBroadcast();
    }
}
