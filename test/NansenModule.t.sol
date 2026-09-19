// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {CustosCore} from "../src/CustosCore.sol";
import {CustosProxy} from "../src/CustosProxy.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {NansenModule} from "../src/modules/NansenModule.sol";
import {
    AttestationInvalid,
    AttestationStale,
    AttestationWalletMismatch,
    NotUpgradeAuthority,
    UnknownAgent
} from "../src/Errors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PriceOracle} from "../src/PriceOracle.sol";

contract NansenModuleTest is Test {
    CustosCore internal custos;
    NansenModule internal nansen;
    address internal nansenImplementation;

    address internal authority = makeAddr("authority");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
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
                    address(new CustosCore()),
                    abi.encodeCall(CustosCore.initialize, (authority, address(usdc)))
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
            bytes32("grid-bot"),
            "trading bot",
            agentWallet,
            4_000 * uint128(USDC),
            1 days,
            1000,
            2000,
            address(0),
            7000,
            true,
            1_000 * uint128(USDC)
        );
    }

    function _sign(bytes32 hash) internal view returns (bytes memory) {
        return _signWith(attestorKey, hash);
    }

    function _signWith(uint256 key, bytes32 hash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, MessageHashUtils.toEthSignedMessageHash(hash));
        return abi.encodePacked(r, s, v);
    }

    function _hash(address wallet, string memory label, int256 pnl, uint16 winRate, uint64 ts)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(wallet, label, pnl, winRate, ts));
    }

    /// @dev Anyone relays; `from` is the relayer, the payload is signed by `key`.
    function _submit(
        address from,
        uint256 key,
        bytes32 id,
        address wallet,
        string memory label,
        int256 pnl,
        uint16 winRate,
        uint64 ts
    ) internal {
        bytes memory sig = _signWith(key, _hash(wallet, label, pnl, winRate, ts));
        vm.prank(from);
        nansen.submitAttestation(id, wallet, label, pnl, winRate, ts, sig);
    }

    function test_anyoneCanRelayAttestorSignedPayload() public {
        bytes32 id = _registerAgent();
        uint64 ts = uint64(block.timestamp);

        _submit(bob, attestorKey, id, alice, "Smart Trader", 42_000, 61, ts); // bob is not the attestor

        (bool valid, address signer) = nansen.verifyAttestation(id, alice, "Smart Trader", 42_000, 61, ts);
        assertTrue(valid);
        assertEq(signer, attestorAddr);
    }

    function test_submitAttestationUnknownAgentReverts() public {
        vm.expectRevert(UnknownAgent.selector);
        _submit(bob, attestorKey, bytes32(uint256(0xdead)), alice, "Smart Trader", 42_000, 61, 1);
    }

    function test_submitAttestationWrongSignerReverts() public {
        bytes32 id = _registerAgent();
        vm.expectRevert(AttestationInvalid.selector);
        _submit(bob, 0xB0B, id, alice, "Smart Trader", 42_000, 61, uint64(block.timestamp));
    }

    function test_submitAttestationForOtherWalletReverts() public {
        bytes32 id = _registerAgent(); // creator is alice
        vm.expectRevert(AttestationWalletMismatch.selector);
        _submit(bob, attestorKey, id, bob, "Fund", 1, 1, uint64(block.timestamp));
    }

    function test_replayOfOlderPayloadReverts() public {
        bytes32 id = _registerAgent();
        uint64 ts = uint64(block.timestamp);
        _submit(bob, attestorKey, id, alice, "Fund", 90_000, 65, ts);

        vm.expectRevert(AttestationStale.selector);
        _submit(bob, attestorKey, id, alice, "Smart Trader", 42_000, 61, ts); // same timestamp
        vm.expectRevert(AttestationStale.selector);
        _submit(bob, attestorKey, id, alice, "Smart Trader", 42_000, 61, ts - 1); // older
    }

    function test_futureTimestampReverts() public {
        bytes32 id = _registerAgent();
        vm.expectRevert(AttestationStale.selector);
        _submit(bob, attestorKey, id, alice, "Fund", 1, 1, uint64(block.timestamp + 6 minutes));
        _submit(bob, attestorKey, id, alice, "Fund", 1, 1, uint64(block.timestamp + 4 minutes)); // within skew
    }

    function test_verifyAttestationWrongDataReturnsFalse() public {
        bytes32 id = _registerAgent();
        uint64 ts = uint64(block.timestamp);
        _submit(bob, attestorKey, id, alice, "Smart Trader", 42_000, 61, ts);

        (bool valid,) = nansen.verifyAttestation(id, alice, "Fund", 42_000, 61, ts);
        assertFalse(valid);
    }

    function test_reattestationOverwritesPrevious() public {
        bytes32 id = _registerAgent();
        uint64 ts = uint64(block.timestamp);
        _submit(bob, attestorKey, id, alice, "Smart Trader", 42_000, 61, ts);
        _submit(bob, attestorKey, id, alice, "Fund", 90_000, 65, ts + 1);

        (bool validOld,) = nansen.verifyAttestation(id, alice, "Smart Trader", 42_000, 61, ts);
        (bool validNew,) = nansen.verifyAttestation(id, alice, "Fund", 90_000, 65, ts + 1);
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
