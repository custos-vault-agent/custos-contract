// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {Attestation, NansenLayout, NansenStorage} from "../storage/NansenStorage.sol";
import {AttestationInvalid, NotAttestor, NotUpgradeAuthority, UnknownAgent, ZeroAddress} from "../Errors.sol";
import {AttestorChanged, NansenAttestationSubmitted} from "../Events.sol";
import {IAgentRegistryExists} from "../interfaces/IAgentRegistryExists.sol";

/// @notice Attestation Nansen on-chain (spec v1 D23, §4.2, §12) — split out of
///         CustosCore purely to bring CustosCore back under the EIP-170
///         24576-byte deployed contract size limit (see
///         docs/superpowers/specs/2026-09-14-nansen-module-split-design.md).
///         Trust model unchanged from before: data is queried off-chain and
///         attested on-chain by a signer Custos controls — not trustless,
///         but verifiable, since anyone can call `verifyAttestation` directly.
contract NansenModule is Initializable, UUPSUpgradeable {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    modifier onlyUpgradeAuthority() {
        if (msg.sender != NansenStorage.layout().upgradeAuthority) revert NotUpgradeAuthority();
        _;
    }

    modifier onlyAttestor() {
        if (msg.sender != NansenStorage.layout().attestor) revert NotAttestor();
        _;
    }

    function initialize(address upgradeAuthority_, address attestor_, address custosCore_) external initializer {
        if (upgradeAuthority_ == address(0) || attestor_ == address(0) || custosCore_ == address(0)) {
            revert ZeroAddress();
        }
        NansenLayout storage $ = NansenStorage.layout();
        $.upgradeAuthority = upgradeAuthority_;
        $.attestor = attestor_;
        $.custosCore = custosCore_;
    }

    function setAttestor(address newAttestor) external onlyUpgradeAuthority {
        if (newAttestor == address(0)) revert ZeroAddress();
        NansenLayout storage $ = NansenStorage.layout();
        emit AttestorChanged($.attestor, newAttestor);
        $.attestor = newAttestor;
    }

    /// @param attestHash keccak256(abi.encode(wallet, label, pnl, winRate, timestamp)).
    /// @param signature ECDSA.sign(attestorKey, toEthSignedMessageHash(attestHash)).
    function submitAttestation(bytes32 agentId, bytes32 attestHash, bytes calldata signature)
        external
        onlyAttestor
    {
        address signer = ECDSA.recoverCalldata(MessageHashUtils.toEthSignedMessageHash(attestHash), signature);
        if (signer != msg.sender) revert AttestationInvalid();

        NansenLayout storage $ = NansenStorage.layout();
        if (!IAgentRegistryExists($.custosCore).agentExists(agentId)) revert UnknownAgent();

        $.attestations[agentId] = Attestation({attestHash: attestHash, signature: signature});

        emit NansenAttestationSubmitted(agentId, attestHash, uint64(block.timestamp));
    }

    /// @notice Verifikasi attestation — pure view, callable oleh siapapun.
    function verifyAttestation(
        bytes32 agentId,
        address wallet,
        string calldata label,
        int256 pnl,
        uint16 winRate,
        uint64 timestamp
    ) external view returns (bool valid, address signer) {
        bytes32 hash = keccak256(abi.encode(wallet, label, pnl, winRate, timestamp));
        Attestation storage a = NansenStorage.layout().attestations[agentId];
        if (hash != a.attestHash) return (false, address(0));

        signer = ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(hash), a.signature);
        valid = signer == NansenStorage.layout().attestor;
    }

    function upgradeAuthority() external view returns (address) {
        return NansenStorage.layout().upgradeAuthority;
    }

    function attestor() external view returns (address) {
        return NansenStorage.layout().attestor;
    }

    function custosCore() external view returns (address) {
        return NansenStorage.layout().custosCore;
    }

    function _authorizeUpgrade(address) internal override onlyUpgradeAuthority {}
}
