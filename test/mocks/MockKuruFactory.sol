// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IKuruFactory} from "../../src/interfaces/IKuruFactory.sol";
import {MockKuruOrderBook} from "./MockKuruOrderBook.sol";

/// @notice Factory Kuru palsu untuk mendaftarkan market baru secara lokal (Anvil), supaya
///         alur "bawa aset baru ke Kuru" bisa dites tanpa testnet asli.
///
/// @dev `deployProxy` tidak mereplikasi CREATE2 atau pola proxy Kuru — ia cukup men-deploy
///      `MockKuruOrderBook` baru, karena `getMarketParams`-lah satu-satunya hal yang pernah
///      dibaca lewat orderbook (lihat `IKuruOrderBook`). Yang ditiru dengan teliti adalah
///      efek yang teramati pemanggil: alamat proxy baru, entri `verifiedMarket`, dan event
///      `MarketRegistered`.
contract MockKuruFactory is IKuruFactory {
    struct VerifiedMarket {
        uint32 pricePrecision;
        uint96 sizePrecision;
        address baseAssetAddress;
        uint256 baseAssetDecimals;
        address quoteAssetAddress;
        uint256 quoteAssetDecimals;
        uint32 tickSize;
        uint96 minSize;
        uint96 maxSize;
        uint256 takerFeeBps;
        uint256 makerFeeBps;
    }

    mapping(address market => VerifiedMarket) internal _verifiedMarket;

    function deployProxy(
        uint8,
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
    ) external returns (address proxy) {
        proxy = address(new MockKuruOrderBook(_baseAssetAddress, _quoteAssetAddress));

        _verifiedMarket[proxy] = VerifiedMarket({
            pricePrecision: _pricePrecision,
            sizePrecision: _sizePrecision,
            baseAssetAddress: _baseAssetAddress,
            baseAssetDecimals: IERC20Metadata(_baseAssetAddress).decimals(),
            quoteAssetAddress: _quoteAssetAddress,
            quoteAssetDecimals: IERC20Metadata(_quoteAssetAddress).decimals(),
            tickSize: _tickSize,
            minSize: _minSize,
            maxSize: _maxSize,
            takerFeeBps: _takerFeeBps,
            makerFeeBps: _makerFeeBps
        });

        emit MarketRegistered(
            _baseAssetAddress,
            _quoteAssetAddress,
            proxy,
            address(0),
            _pricePrecision,
            _sizePrecision,
            _tickSize,
            _minSize,
            _maxSize,
            _takerFeeBps,
            _makerFeeBps,
            _kuruAmmSpread
        );
    }

    function verifiedMarket(address market)
        external
        view
        returns (
            uint32,
            uint96,
            address,
            uint256,
            address,
            uint256,
            uint32,
            uint96,
            uint96,
            uint256,
            uint256
        )
    {
        VerifiedMarket storage m = _verifiedMarket[market];
        return (
            m.pricePrecision,
            m.sizePrecision,
            m.baseAssetAddress,
            m.baseAssetDecimals,
            m.quoteAssetAddress,
            m.quoteAssetDecimals,
            m.tickSize,
            m.minSize,
            m.maxSize,
            m.takerFeeBps,
            m.makerFeeBps
        );
    }
}
