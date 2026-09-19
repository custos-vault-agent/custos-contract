// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Custos's permanent address; all registry state lives here.
/// @dev UUPS: upgrade logic is in the implementation (`_authorizeUpgrade`), so the proxy
///      has no admin functions that could clash with module selectors.
contract CustosProxy is ERC1967Proxy {
    constructor(address implementation, bytes memory data) ERC1967Proxy(implementation, data) {}
}
