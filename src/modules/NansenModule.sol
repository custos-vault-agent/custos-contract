// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {Attestation, NansenLayout, NansenStorage} from "../storage/NansenStorage.sol";
import {
    AttestationInvalid,
    AttestationStale,
    AttestationWalletMismatch,
    NotUpgradeAuthority,
    UnknownAgent,
    ZeroAddress
} from "../Errors.sol";
import {AttestorChanged, NansenAttestationSubmitted, UpgradeAuthorityChanged} from "../Events.sol";
import {IAgentRegistry} from "../interfaces/IAgentRegistry.sol";
import {AgentRecord, Status} from "../Types.sol";

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

    function initialize(address upgradeAuthority_, address attestor_, address custosCore_)
        external
        initializer
    {
        if (upgradeAuthority_ == address(0) || attestor_ == address(0) || custosCore_ == address(0)) {
            revert ZeroAddress();
        }
        NansenLayout storage $ = NansenStorage.layout();
        $.upgradeAuthority = upgradeAuthority_;
        $.attestor = attestor_;
        $.custosCore = custosCore_;
    }

    function transferUpgradeAuthority(address newAuthority) external onlyUpgradeAuthority {
        if (newAuthority == address(0)) revert ZeroAddress();
        NansenLayout storage $ = NansenStorage.layout();
        emit UpgradeAuthorityChanged($.upgradeAuthority, newAuthority);
        $.upgradeAuthority = newAuthority;
    }

    function setAttestor(address newAttestor) external onlyUpgradeAuthority {
        if (newAttestor == address(0)) revert ZeroAddress();
        NansenLayout storage $ = NansenStorage.layout();
        emit AttestorChanged($.attestor, newAttestor);
        $.attestor = newAttestor;
    }

    /// @dev Skew tolerated on the payload timestamp; the attestor's clock vs. the chain's.
    uint64 internal constant MAX_FUTURE = 5 minutes;

    /// @notice Pull model (like Pyth's `updatePriceFeeds`): anyone may relay a payload
    ///         the attestor signed off-chain. The contract binds it to the agent
    ///         (`wallet` must be the creator) and refuses replays (timestamp must be
    ///         newer than the stored one).
    /// @param signature ECDSA over toEthSignedMessageHash(keccak256(abi.encode(
    ///        wallet, label, pnl, winRate, timestamp))), by `attestor`.
    function submitAttestation(
        bytes32 agentId,
        address wallet,
        string calldata label,
        int256 pnl,
        uint16 winRate,
        uint64 timestamp,
        bytes calldata signature
    ) external {
        NansenLayout storage $ = NansenStorage.layout();

        AgentRecord memory agent = IAgentRegistry($.custosCore).getAgent(agentId);
        if (agent.status == Status.None) revert UnknownAgent();
        if (agent.creator != wallet) revert AttestationWalletMismatch();

        Attestation storage current = $.attestations[agentId];
        if (timestamp <= current.timestamp || timestamp > block.timestamp + MAX_FUTURE) {
            revert AttestationStale();
        }

        bytes32 attestHash = keccak256(abi.encode(wallet, label, pnl, winRate, timestamp));
        address signer = ECDSA.recoverCalldata(MessageHashUtils.toEthSignedMessageHash(attestHash), signature);
        if (signer != $.attestor) revert AttestationInvalid();

        $.attestations[agentId] =
            Attestation({attestHash: attestHash, signature: signature, timestamp: timestamp});

        emit NansenAttestationSubmitted(agentId, wallet, label, pnl, winRate, timestamp, attestHash);
    }

    /// @notice Verifies an attestation — view, callable by anyone.
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
