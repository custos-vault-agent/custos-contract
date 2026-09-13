// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IKuruOrderBook} from "../../src/interfaces/IKuruOrderBook.sol";

/// @notice Orderbook Kuru palsu. Yang ditiru hanya `getMarketParams`, karena hanya itu
///         yang dibaca adapter — tapi ditiru **utuh sebelas field**, bukan dua yang
///         dipakai. Tuple yang dipendekkan akan membuat test lolos sementara decoding di
///         mainnet mengambil kata yang salah.
contract MockKuruOrderBook is IKuruOrderBook {
    address public immutable base;
    address public immutable quote;

    constructor(address base_, address quote_) {
        base = base_;
        quote = quote_;
    }

    function getMarketParams()
        external
        view
        returns (uint32, uint96, address, uint256, address, uint256, uint32, uint96, uint96, uint256, uint256)
    {
        return (
            1e2, // pricePrecision
            1e10, // sizePrecision
            base, // <- indeks 2
            18, // baseAssetDecimals
            quote, // <- indeks 4
            6, // quoteAssetDecimals
            1, // tickSize
            1e6, // minSize
            type(uint96).max, // maxSize
            30, // takerFeeBps
            10 // makerFeeBps
        );
    }
}
