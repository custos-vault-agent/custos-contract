// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice On-chain agent status (spec D6).
/// @dev `None` is index 0 so an empty slot never reads as Active.
enum Status {
    None,
    Active,
    Paused,
    Revoked
}

/// @notice One agent's registry record. Its vault (AgentVault) and Nansen attestation
///         (NansenModule) live in separate contracts — spec v1 D13.
/// @dev Slot layout (spec v1 §3.1) — never reorder after deploy:
///        0: name
///        1: wallet (160) + status (8)
///        2: creator
///        3: vault
///        4: descriptionHash
///        5: feeRate (16) + isPublic (8) + registeredAt (64)
struct AgentRecord {
    bytes32 name;
    address wallet;
    Status status;
    address creator;
    address vault;
    bytes32 descriptionHash;
    uint16 feeRate;
    bool isPublic;
    uint64 registeredAt;
}
