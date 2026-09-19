// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {CustosCore} from "../src/CustosCore.sol";
import {CustosProxy} from "../src/CustosProxy.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {NansenModule} from "../src/modules/NansenModule.sol";
import {AttestationInvalid, NotAttestor, NotUpgradeAuthority, UnknownAgent} from "../src/Errors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PriceOracle} from "../src/PriceOracle.sol";

contract NansenModuleTest is Test {
    CustosCore internal custos;
    NansenModule internal nansen;
    address internal nansenImplementation;

    address internal authority = makeAddr("authority");
    address internal alice = makeAddr("alice");
    address internal agentWallet = makeAddr("agentWallet");

    uint256 internal constant USDC = 1e6;
    uint128 internal constant MIN_SEED = 500 * 1e6;

    uint256 internal attestorKey = 0xA11CE;
    address internal attestorAddr;

    function setUp() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);

        custos = CustosCore(
            address(
                new CustosProxy(
                    address(new CustosCore()), abi.encodeCall(CustosCore.initialize, (authority, address(usdc)))
                )
            )
        );
        vm.startPrank(authority);
        custos.setMinSeed(MIN_SEED);
        custos.setMarketAdapter(makeAddr("market")); // never called in these tests, just non-zero
        custos.setPriceOracle(address(new PriceOracle(authority, address(usdc)))); // idem
        custos.setVaultFactory(address(new VaultFactory(address(custos))));
        vm.stopPrank();

        attestorAddr = vm.addr(attestorKey);
        nansenImplementation = address(new NansenModule());
        nansen = NansenModule(
            address(
                new CustosProxy(
                    nansenImplementation,
                    abi.encodeCall(NansenModule.initialize, (authority, attestorAddr, address(custos)))
                )
            )
        );

        usdc.mint(alice, 1_000_000 * USDC);
        vm.prank(alice);
        usdc.approve(address(custos), type(uint256).max);
    }

    function _registerAgent() internal returns (bytes32 id) {
        vm.prank(alice);
        (id,) = custos.registerAgent(
            bytes32("grid-bot"), "trading bot", agentWallet, 4_000 * uint128(USDC), 1 days, 1000, 2000,
            address(0), 7000, true, 1_000 * uint128(USDC)
        );
    }

    function _sign(bytes32 hash) internal view returns (bytes memory) {
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(hash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attestorKey, ethHash);
        return abi.encodePacked(r, s, v);
    }

    function test_submitAttestationByAttestor() public {
        bytes32 id = _registerAgent();
        bytes32 attestHash =
            keccak256(abi.encode(alice, "Smart Trader", int256(42_000), uint16(6100), uint64(1)));

        vm.prank(attestorAddr);
        nansen.submitAttestation(id, attestHash, _sign(attestHash));

        (bool valid, address signer) =
            nansen.verifyAttestation(id, alice, "Smart Trader", int256(42_000), uint16(6100), uint64(1));
        assertTrue(valid);
        assertEq(signer, attestorAddr);
    }

    function test_submitAttestationNotAttestorReverts() public {
        bytes32 id = _registerAgent();
        bytes32 attestHash =
            keccak256(abi.encode(alice, "Smart Trader", int256(42_000), uint16(6100), uint64(1)));

        vm.prank(alice);
        vm.expectRevert(NotAttestor.selector);
        nansen.submitAttestation(id, attestHash, _sign(attestHash));
    }

    function test_submitAttestationUnknownAgentReverts() public {
        bytes32 unknownId = bytes32(uint256(0xdead));
        bytes32 attestHash =
            keccak256(abi.encode(alice, "Smart Trader", int256(42_000), uint16(6100), uint64(1)));

        vm.prank(attestorAddr);
        vm.expectRevert(UnknownAgent.selector);
        nansen.submitAttestation(unknownId, attestHash, _sign(attestHash));
    }

    function test_submitAttestationWrongSignerReverts() public {
        bytes32 id = _registerAgent();
        bytes32 attestHash =
            keccak256(abi.encode(alice, "Smart Trader", int256(42_000), uint16(6100), uint64(1)));
        uint256 wrongKey = 0xB0B;
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(attestHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, ethHash);

        vm.prank(attestorAddr);
        vm.expectRevert(AttestationInvalid.selector);
        nansen.submitAttestation(id, attestHash, abi.encodePacked(r, s, v));
    }

    function test_verifyAttestationWrongDataReturnsFalse() public {
        bytes32 id = _registerAgent();
        bytes32 attestHash =
            keccak256(abi.encode(alice, "Smart Trader", int256(42_000), uint16(6100), uint64(1)));

        vm.prank(attestorAddr);
        nansen.submitAttestation(id, attestHash, _sign(attestHash));

        (bool valid,) = nansen.verifyAttestation(id, alice, "Fund", int256(42_000), uint16(6100), uint64(1));
        assertFalse(valid);
    }

    function test_reattestationOverwritesPrevious() public {
        bytes32 id = _registerAgent();
        bytes32 firstHash =
            keccak256(abi.encode(alice, "Smart Trader", int256(42_000), uint16(6100), uint64(1)));
        bytes32 secondHash = keccak256(abi.encode(alice, "Fund", int256(90_000), uint16(6500), uint64(2)));

        vm.prank(attestorAddr);
        nansen.submitAttestation(id, firstHash, _sign(firstHash));
        vm.prank(attestorAddr);
        nansen.submitAttestation(id, secondHash, _sign(secondHash));

        (bool validOld,) =
            nansen.verifyAttestation(id, alice, "Smart Trader", int256(42_000), uint16(6100), uint64(1));
        (bool validNew,) = nansen.verifyAttestation(id, alice, "Fund", int256(90_000), uint16(6500), uint64(2));
        assertFalse(validOld);
        assertTrue(validNew);
    }

    function test_setAttestorOnlyUpgradeAuthority() public {
        vm.prank(alice);
        vm.expectRevert(NotUpgradeAuthority.selector);
        nansen.setAttestor(alice);
    }

    function test_implementationCannotBeInitialized() public {
        vm.expectRevert();
        NansenModule(nansenImplementation).initialize(alice, alice, address(custos));
    }
}
