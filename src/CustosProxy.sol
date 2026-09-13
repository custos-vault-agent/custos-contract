// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Alamat permanen Custos. Di sinilah seluruh dana dan state berada.
/// @dev UUPS: logika upgrade ada di implementation (`_authorizeUpgrade`), bukan di sini,
///      sehingga proxy tidak punya fungsi admin yang bisa bentrok dengan selector modul.
contract CustosProxy is ERC1967Proxy {
    constructor(address implementation, bytes memory data) ERC1967Proxy(implementation, data) {}
}
