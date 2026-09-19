// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Kuru router — the one function Custos calls.
///
/// @dev Signature copied from kuru-sdk's `abi/Router.json`; the mainnet router
///      implementation (`0xd651346d7c789536ebf06dc72aE3C8502cd695CC`, ERC-1967) is
///      unverified on the explorer, so the SDK ABI is the available source of truth.
///
///      Via the router, not the orderbook directly: the orderbook's market-order
///      functions take sizes in precision units (`uint96`, scaled by
///      `sizePrecision`/`pricePrecision`) while `anyToAnySwap` takes raw token
///      decimals — one less conversion to get wrong.
interface IKuruRouter {
    /// @notice Swaps `_amount` of `_debitToken` into `_creditToken` through one or more
    ///         orderbooks.
    ///
    /// @param _marketAddresses Route: one orderbook per hop.
    /// @param _isBuy Direction per hop, aligned with `_marketAddresses`.
    /// @param _nativeSend Whether a hop sends native MON. Always `false` for Custos.
    /// @param _debitToken Token spent; the router pulls it from `msg.sender`.
    /// @param _creditToken Token received; the router sends it to `msg.sender`.
    /// @param _amount Amount of `_debitToken`, in token decimals.
    /// @param _minAmountOut Slippage bound; the router reverts if not met.
    function anyToAnySwap(
        address[] calldata _marketAddresses,
        bool[] calldata _isBuy,
        bool[] calldata _nativeSend,
        address _debitToken,
        address _creditToken,
        uint256 _amount,
        uint256 _minAmountOut
    ) external payable returns (uint256 _amountOut);
}
