// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Kuru factory — used to register new markets, not to swap.
///
/// @dev Signatures copied from the on-chain ABI on Monad testnet
///      (`0x7EFbE105Ca7415dE98F96622173458ac1c054630`). Only `deployProxy` and
///      `verifiedMarket` are copied; the rest of the ABI is Kuru's own lifecycle.
///
///      `_type` is `uint8` rather than Kuru's `OrderBookType` enum: Solidity encodes
///      enums as their underlying integer, so the selector is identical.
interface IKuruFactory {
    event MarketRegistered(
        address baseAsset,
        address quoteAsset,
        address market,
        address vaultAddress,
        uint32 pricePrecision,
        uint96 sizePrecision,
        uint32 tickSize,
        uint96 minSize,
        uint96 maxSize,
        uint256 takerFeeBps,
        uint256 makerFeeBps,
        uint96 kuruAmmSpread
    );

    /// @notice Registers a new asset pair as a Kuru market and deploys its orderbook.
    /// @return proxy The new orderbook — what `KuruMarketAdapter` wraps.
    function deployProxy(
        uint8 _type,
        address _baseAssetAddress,
        address _quoteAssetAddress,
        uint96 _sizePrecision,
        uint32 _pricePrecision,
        uint32 _tickSize,
        uint96 _minSize,
        uint96 _maxSize,
        uint256 _takerFeeBps,
        uint256 _makerFeeBps,
        uint96 _kuruAmmSpread
    ) external returns (address proxy);

    /// @notice The factory's recorded params for `market`; same tuple order as
    ///         `IKuruOrderBook.getMarketParams`.
    function verifiedMarket(address market)
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
