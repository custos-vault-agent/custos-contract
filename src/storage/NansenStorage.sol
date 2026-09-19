// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @custom:storage-location erc7201:custos.storage.nansen
struct NansenLayout {
    address upgradeAuthority;
    address attestor; // signs Nansen attestations (D23)
    address custosCore; // registry used for agentExists(); set once, no setter
    mapping(bytes32 agentId => Attestation) attestations;
}

struct Attestation {
    bytes32 attestHash;
    bytes signature;
}

library NansenStorage {
    /// @dev keccak256(abi.encode(uint256(keccak256("custos.storage.nansen")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT = 0x4a710a2493b1c5f8e955844d219a33160d2200c1e3e0b96f8119dff39e5b5500;

    function layout() internal pure returns (NansenLayout storage $) {
        assembly {
            $.slot := SLOT
        }
    }
}
