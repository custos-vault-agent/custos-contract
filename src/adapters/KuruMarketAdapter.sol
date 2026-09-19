// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IKuruOrderBook} from "../interfaces/IKuruOrderBook.sol";
import {IKuruRouter} from "../interfaces/IKuruRouter.sol";
import {IMarket} from "../interfaces/IMarket.sol";
import {ZeroAddress} from "../Errors.sol";

/// @notice Wraps one Kuru market as the `IMarket` shape Custos understands.
///
/// @dev One adapter per orderbook, on purpose: the allowance model rests on
///      `quoteToken() == accountingAsset`, which only means something for a fixed
///      market. An adapter that routed anywhere would make the `setMarketAllowed`
///      check meaningless after the first pass.
///
///      **The adapter holds no trust.** No owner, no state, no funds between
///      transactions. It can only move tokens pulled from `msg.sender` in the same
///      call and returns everything to `msg.sender`. The vault measures its own
///      balance deltas rather than trusting the return value.
contract KuruMarketAdapter is IMarket {
    using SafeERC20 for IERC20;

    IKuruRouter public immutable router;
    address public immutable orderbook;

    address internal immutable _base;
    address internal immutable _quote;

    constructor(IKuruRouter router_, address orderbook_) {
        if (address(router_) == address(0) || orderbook_ == address(0)) revert ZeroAddress();
        router = router_;
        orderbook = orderbook_;

        // Read once and frozen: re-reading per swap would let an upgraded market swap
        // base/quote under an allowlist that already approved it.
        (,, address baseAsset,, address quoteAsset,,,,,,) = IKuruOrderBook(orderbook_).getMarketParams();
        if (baseAsset == address(0) || quoteAsset == address(0)) revert ZeroAddress();
        _base = baseAsset;
        _quote = quoteAsset;
    }

    function baseToken() external view returns (address) {
        return _base;
    }

    function quoteToken() external view returns (address) {
        return _quote;
    }

    /// @inheritdoc IMarket
    function swap(bool isBuy, uint256 amountIn, uint256 minAmountOut) external returns (uint256 amountOut) {
        (address tokenIn, address tokenOut) = isBuy ? (_quote, _base) : (_base, _quote);

        // Snapshot before pulling so the delta is this swap's only; reading the full
        // balance at the end would sweep stray tokens to the next caller.
        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        _route(isBuy, tokenIn, tokenOut, amountIn, minAmountOut);

        // Always clear leftover approval; a partial-fill router must not keep a live
        // claim on this adapter.
        IERC20(tokenIn).forceApprove(address(router), 0);

        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        uint256 unspent = IERC20(tokenIn).balanceOf(address(this)) - inBefore;

        // Nothing stays in the adapter: everything goes back to the caller.
        if (unspent != 0) IERC20(tokenIn).safeTransfer(msg.sender, unspent);
        if (amountOut != 0) IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }

    /// @dev Builds a one-hop route and calls the router. Split from `swap` to stay
    ///      under solc's 16-slot stack limit.
    function _route(bool isBuy, address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        internal
    {
        address[] memory route = new address[](1);
        route[0] = orderbook;
        bool[] memory sides = new bool[](1);
        sides[0] = isBuy;
        // ERC-20 only; the native path is never used and `msg.value` is always zero.
        bool[] memory nativeSend = new bool[](1);

        router.anyToAnySwap(route, sides, nativeSend, tokenIn, tokenOut, amountIn, minAmountOut);
    }
}
