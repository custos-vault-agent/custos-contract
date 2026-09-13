// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {AccessControl} from "./AccessControl.sol";
import {AccessStorage} from "../storage/AccessStorage.sol";
import {AgentRecord, Status} from "../Types.sol";
import {RegistryStorage} from "../storage/RegistryStorage.sol";
import {AttestationInvalid, UnknownAgent} from "../Errors.sol";
import {NansenAttestationSubmitted} from "../Events.sol";

/// @notice Attestation Nansen on-chain (spec v1 D23, §4.2, §12).
///
/// @dev Trust model, jujur ke siapa pun yang membaca kode ini: data Nansen di-query
///      off-chain, lalu di-attest on-chain oleh signer yang di-kontrol Custos. Ini
///      bukan trustless — backend harus jujur men-query Nansen — tapi *verifiable*:
///      siapa pun bisa memanggil `verifyAttestation` langsung, tanpa perlu percaya
///      frontend Custos sama sekali. Attestor sendiri dikontrol upgradeAuthority
///      (multisig + timelock), jadi kompromi attestor tunduk pada tata kelola yang
///      sama seperti upgrade CustosCore.
abstract contract NansenAttestation is AccessControl {
    /// @notice Tulis attestation Nansen on-chain untuk sebuah agent. Hanya attestor.
    /// @param attestHash keccak256(abi.encode(wallet, label, pnl, winRate, timestamp)).
    /// @param signature ECDSA.sign(attestorKey, toEthSignedMessageHash(attestHash)).
    function submitAttestation(bytes32 agentId, bytes32 attestHash, bytes calldata signature)
        external
        onlyAttestor
    {
        // Memverifikasi signature, bukan hanya mempercayai bahwa pemanggil adalah
        // attestor: ini membuktikan kunci privat attestor yang benar-benar
        // menandatangani hash ini, bukan sekadar bahwa alamat pemanggil cocok.
        address signer = ECDSA.recoverCalldata(MessageHashUtils.toEthSignedMessageHash(attestHash), signature);
        if (signer != msg.sender) revert AttestationInvalid();

        AgentRecord storage a = RegistryStorage.layout().agents[agentId];
        if (a.status == Status.None) revert UnknownAgent();

        a.nansenAttestHash = attestHash;
        a.nansenSignature = signature;

        emit NansenAttestationSubmitted(agentId, a.creator, attestHash, uint64(block.timestamp));
    }

    /// @notice Verifikasi attestation — pure view, callable oleh siapapun, termasuk
    ///         kontrak lain yang ingin memakai ini sebagai composable trust layer.
    function verifyAttestation(
        bytes32 agentId,
        address wallet,
        string calldata label,
        int256 pnl,
        uint16 winRate,
        uint64 timestamp
    ) external view returns (bool valid, address signer) {
        bytes32 hash = keccak256(abi.encode(wallet, label, pnl, winRate, timestamp));
        AgentRecord storage a = RegistryStorage.layout().agents[agentId];
        if (hash != a.nansenAttestHash) return (false, address(0));

        signer = ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(hash), a.nansenSignature);
        valid = signer == AccessStorage.layout().attestor;
    }
}
