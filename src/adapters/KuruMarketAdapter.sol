// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IKuruOrderBook} from "../interfaces/IKuruOrderBook.sol";
import {IKuruRouter} from "../interfaces/IKuruRouter.sol";
import {IMarket} from "../interfaces/IMarket.sol";
import {IWrappedNative} from "../interfaces/IWrappedNative.sol";
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
///
///      **Native markets.** Kuru reports the native token as the zero address, and
///      its router then moves native value instead of an ERC-20. Custos moves ERC-20
///      only, so this adapter wraps and unwraps inside the call: it reports the
///      wrapped token as `baseToken()`, hands the vault WMON after a buy, and unwraps
///      WMON before a sell. Native value exists here for the length of one call and
///      never reaches the vault.
contract KuruMarketAdapter is IMarket {
    using SafeERC20 for IERC20;

    IKuruRouter public immutable router;
    address public immutable orderbook;
    /// @dev True when the orderbook trades the native token as its base.
    bool public immutable nativeBase;

    address internal immutable _base;
    address internal immutable _quote;

    /// @param wrappedNative_ Required only for a native market; ignored otherwise.
    constructor(IKuruRouter router_, address orderbook_, address wrappedNative_) {
        if (address(router_) == address(0) || orderbook_ == address(0)) revert ZeroAddress();
        router = router_;
        orderbook = orderbook_;

        // Read once and frozen: re-reading per swap would let an upgraded market swap
        // base/quote under an allowlist that already approved it.
        (,, address baseAsset,, address quoteAsset,,,,,,) = IKuruOrderBook(orderbook_).getMarketParams();
        if (quoteAsset == address(0)) revert ZeroAddress();

        nativeBase = baseAsset == address(0);
        if (nativeBase && wrappedNative_ == address(0)) revert ZeroAddress();
        _base = nativeBase ? wrappedNative_ : baseAsset;
        _quote = quoteAsset;
    }

    /// @dev The router pays a native market out as value. Only reachable during `swap`,
    ///      which wraps whatever arrives before it returns.
    receive() external payable {}

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
        uint256 nativeBefore = address(this).balance;

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        if (nativeBase) {
            _swapNative(isBuy, amountIn, minAmountOut, nativeBefore);
        } else {
            IERC20(tokenIn).forceApprove(address(router), amountIn);
            _route(isBuy, tokenIn, tokenOut, amountIn, minAmountOut, false);
            // Always clear leftover approval; a partial-fill router must not keep a
            // live claim on this adapter.
            IERC20(tokenIn).forceApprove(address(router), 0);
        }

        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        uint256 unspent = IERC20(tokenIn).balanceOf(address(this)) - inBefore;

        // Nothing stays in the adapter: everything goes back to the caller.
        if (unspent != 0) IERC20(tokenIn).safeTransfer(msg.sender, unspent);
        if (amountOut != 0) IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }

    /// @dev A native market, seen from the outside as an ordinary WMON market. Every
    ///      unit of native value this creates is wrapped again before it returns, so
    ///      the balance deltas in `swap` stay ERC-20 and the adapter keeps nothing.
    function _swapNative(bool isBuy, uint256 amountIn, uint256 minAmountOut, uint256 nativeBefore) internal {
        if (isBuy) {
            IERC20(_quote).forceApprove(address(router), amountIn);
            _route(true, _quote, address(0), amountIn, minAmountOut, false);
            IERC20(_quote).forceApprove(address(router), 0);
        } else {
            // The router spends native, so the WMON the vault sent has to come out of
            // its wrapper first.
            IWrappedNative(_base).withdraw(amountIn);
            _route(false, address(0), _quote, amountIn, minAmountOut, true);
        }

        // Whatever native is here is either the proceeds of a buy or the unspent part
        // of a partial sell. Both belong to the caller, and the caller takes ERC-20.
        uint256 native = address(this).balance - nativeBefore;
        if (native != 0) IWrappedNative(_base).deposit{value: native}();
    }

    /// @dev Builds a one-hop route and calls the router. Split from `swap` to stay
    ///      under solc's 16-slot stack limit.
    /// @param nativeIn The router reads the debited amount from `msg.value` instead of
    ///        pulling an ERC-20. `tokenIn` is then the zero address.
    function _route(
        bool isBuy,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bool nativeIn
    ) internal {
        address[] memory route = new address[](1);
        route[0] = orderbook;
        bool[] memory sides = new bool[](1);
        sides[0] = isBuy;
        bool[] memory nativeSend = new bool[](1);
        nativeSend[0] = nativeIn;

        router.anyToAnySwap{value: nativeIn ? amountIn : 0}(
            route, sides, nativeSend, tokenIn, tokenOut, amountIn, minAmountOut
        );
    }
}
