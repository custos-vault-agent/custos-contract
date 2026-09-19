// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMarket} from "../interfaces/IMarket.sol";
import {ZeroAddress} from "../Errors.sol";

/// @notice Fixed-price two-token market, for demo trading until a real Kuru
///         market exists on Monad to point at.
///
/// @dev Deployed for real by the deploy script, hence `src/adapters/` rather than
///      `test/mocks/`. No misbehaviour knobs: its only job is to behave correctly.
contract FixedPriceMarket is IMarket {
    using SafeERC20 for IERC20;

    address public immutable base;
    address public immutable quote;
    address public immutable owner;

    /// @dev Price: `priceNum` units of quote per `priceDen` units of base.
    uint256 public priceNum;
    uint256 public priceDen;

    event PriceChanged(uint256 oldPriceNum, uint256 oldPriceDen, uint256 newPriceNum, uint256 newPriceDen);

    error NotOwner();
    error MarketSlippage();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address base_, address quote_, uint256 priceNum_, uint256 priceDen_) {
        if (base_ == address(0) || quote_ == address(0)) revert ZeroAddress();
        base = base_;
        quote = quote_;
        priceNum = priceNum_;
        priceDen = priceDen_;
        owner = msg.sender;
    }

    function baseToken() external view returns (address) {
        return base;
    }

    function quoteToken() external view returns (address) {
        return quote;
    }

    /// @notice Moves the demo price so seeded swaps produce real share-price swings.
    function setPrice(uint256 num, uint256 den) external onlyOwner {
        emit PriceChanged(priceNum, priceDen, num, den);
        priceNum = num;
        priceDen = den;
    }

    function swap(bool isBuy, uint256 amountIn, uint256 minAmountOut) external returns (uint256 amountOut) {
        (address tokenIn, address tokenOut) = isBuy ? (quote, base) : (base, quote);
        amountOut = isBuy ? (amountIn * priceDen) / priceNum : (amountIn * priceNum) / priceDen;
        if (amountOut < minAmountOut) revert MarketSlippage();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }
}
