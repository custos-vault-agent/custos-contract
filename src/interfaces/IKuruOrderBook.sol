// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The slice of Kuru's orderbook interface Custos actually uses.
///
/// @dev Only `getMarketParams`: it tells the adapter a market's base and quote tokens,
///      and `setMarketAllowed` rejects markets whose quote is not the accounting
///      asset (D4).
interface IKuruOrderBook {
    /// @notice Market params, in exactly the order Kuru's contract returns them.
    ///
    /// @dev Tuple order verified against kuru-sdk's `ParamFetcher.getMarketParams`:
    ///      index 2 is base, index 4 is quote. Swapping them would compile and then
    ///      charge notional in the wrong currency.
    function getMarketParams()
        external
        view
        returns (
            uint32 pricePrecision,
            uint96 sizePrecision,
            address baseAssetAddress,
            uint256 baseAssetDecimals,
            address quoteAssetAddress,
            uint256 quoteAssetDecimals,
            uint32 tickSize,
            uint96 minSize,
            uint96 maxSize,
            uint256 takerFeeBps,
            uint256 makerFeeBps
        );
}
