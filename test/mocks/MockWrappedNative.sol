// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice WMON/WETH shape: an ERC-20 that mints on `deposit` and burns on `withdraw`,
///         always one to one with the native token.
contract MockWrappedNative is ERC20 {
    error WithdrawFailed();

    constructor() ERC20("Wrapped Monad", "WMON") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert WithdrawFailed();
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}
