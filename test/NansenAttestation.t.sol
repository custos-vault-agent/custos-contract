// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {Base} from "./Base.t.sol";
import {AttestationInvalid, NotAttestor} from "../src/Errors.sol";

contract NansenAttestationTest is Base {
    uint256 internal attestorKey = 0xA11CE;
    address internal attestorAddr;

    function setUp() public override {
        super.setUp();
        attestorAddr = vm.addr(attestorKey);
        vm.prank(authority);
        custos.setAttestor(attestorAddr);
    }

    function _sign(bytes32 hash) internal view returns (bytes memory) {
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(hash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attestorKey, ethHash);
        return abi.encodePacked(r, s, v);
    }

    function test_submitAttestationByAttestor() public {
        (bytes32 id,) = _registerAgent(alice, agentWallet, 4_000 * uint128(USDC), 1 days);
        bytes32 attestHash = keccak256(abi.encode(alice, "Smart Trader", int256(42_000), uint16(6100), uint64(1)));

        vm.prank(attestorAddr);
        custos.submitAttestation(id, attestHash, _sign(attestHash));

        assertEq(custos.getAgent(id).nansenAttestHash, attestHash);
    }

    function test_submitAttestationNotAttestorReverts() public {
        (bytes32 id,) = _registerAgent(alice, agentWallet, 4_000 * uint128(USDC), 1 days);
        bytes32 attestHash = keccak256(abi.encode(alice, "Smart Trader", int256(42_000), uint16(6100), uint64(1)));

        vm.prank(alice);
        vm.expectRevert(NotAttestor.selector);
        custos.submitAttestation(id, attestHash, _sign(attestHash));
    }

    function test_verifyAttestationValid() public {
        (bytes32 id,) = _registerAgent(alice, agentWallet, 4_000 * uint128(USDC), 1 days);
        int256 pnl = 42_000;
        uint16 winRate = 6100;
        uint64 timestamp = uint64(block.timestamp);
        bytes32 attestHash = keccak256(abi.encode(alice, "Smart Trader", pnl, winRate, timestamp));

        vm.prank(attestorAddr);
        custos.submitAttestation(id, attestHash, _sign(attestHash));

        (bool valid, address signer) = custos.verifyAttestation(id, alice, "Smart Trader", pnl, winRate, timestamp);
        assertTrue(valid);
        assertEq(signer, attestorAddr);
    }

    function test_verifyAttestationWrongData() public {
        (bytes32 id,) = _registerAgent(alice, agentWallet, 4_000 * uint128(USDC), 1 days);
        bytes32 attestHash = keccak256(abi.encode(alice, "Smart Trader", int256(42_000), uint16(6100), uint64(1)));

        vm.prank(attestorAddr);
        custos.submitAttestation(id, attestHash, _sign(attestHash));

        (bool valid,) = custos.verifyAttestation(id, alice, "Fund", int256(42_000), uint16(6100), uint64(1));
        assertFalse(valid);
    }

    function test_reattestationOverwritesPrevious() public {
        (bytes32 id,) = _registerAgent(alice, agentWallet, 4_000 * uint128(USDC), 1 days);
        bytes32 firstHash = keccak256(abi.encode(alice, "Smart Trader", int256(42_000), uint16(6100), uint64(1)));
        bytes32 secondHash = keccak256(abi.encode(alice, "Fund", int256(90_000), uint16(6500), uint64(2)));

        vm.prank(attestorAddr);
        custos.submitAttestation(id, firstHash, _sign(firstHash));
        vm.prank(attestorAddr);
        custos.submitAttestation(id, secondHash, _sign(secondHash));

        (bool validOld,) = custos.verifyAttestation(id, alice, "Smart Trader", int256(42_000), uint16(6100), uint64(1));
        (bool validNew,) = custos.verifyAttestation(id, alice, "Fund", int256(90_000), uint16(6500), uint64(2));
        assertFalse(validOld);
        assertTrue(validNew);
    }

    function test_setAttestorOnlyUpgradeAuthority() public {
        vm.prank(alice);
        vm.expectRevert(); // NotUpgradeAuthority
        custos.setAttestor(alice);
    }
}
