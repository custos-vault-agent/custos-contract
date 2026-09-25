// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IKuruOrderBook} from "../../src/interfaces/IKuruOrderBook.sol";
import {IKuruRouter} from "../../src/interfaces/IKuruRouter.sol";

/// @notice Router Kuru palsu dengan tanda tangan `anyToAnySwap` yang persis sama dengan
///         router mainnet (`0xd651346d7c789536ebf06dc72aE3C8502cd695CC`).
///
/// @dev Yang ditiru bukan cuma bentuk panggilannya, melainkan **konvensi alirannya**:
///      router menarik `_debitToken` dari `msg.sender` lewat `transferFrom`, dan mengirim
///      `_creditToken` balik ke `msg.sender`. Adapter yang salah menebak arah ini akan
///      lulus semua test dengan mock yang lebih longgar, lalu kehilangan dana di mainnet.
///
///      Seperti `MockMarket`, mock ini sengaja bisa berperilaku buruk — `spendBps` untuk
///      fill sebagian dan `payoutBps` untuk harga yang meleset — karena justru perilaku
///      itulah yang harus ditangani jalur akuntansi Custos dengan benar.
contract MockKuruRouter is IKuruRouter {
    /// @dev Harga per orderbook: `priceNum` unit quote per `priceDen` unit base.
    mapping(address orderbook => uint256) public priceNum;
    mapping(address orderbook => uint256) public priceDen;

    uint256 public spendBps = 10_000;
    uint256 public payoutBps = 10_000;

    error MockRouterSlippage();
    error MockRouterUnsupportedRoute();

    function setPrice(address orderbook, uint256 num, uint256 den) external {
        priceNum[orderbook] = num;
        priceDen[orderbook] = den;
    }

    function setSpendBps(uint256 bps) external {
        spendBps = bps;
    }

    function setPayoutBps(uint256 bps) external {
        payoutBps = bps;
    }

    function anyToAnySwap(
        address[] calldata _marketAddresses,
        bool[] calldata _isBuy,
        bool[] calldata _nativeSend,
        address _debitToken,
        address _creditToken,
        uint256 _amount,
        uint256 _minAmountOut
    ) external payable returns (uint256 _amountOut) {
        // Custos selalu satu hop. Rute lain ditolak keras supaya adapter yang diam-diam
        // mulai mengirimkan bentuk lain ketahuan di test.
        if (_marketAddresses.length != 1 || _isBuy.length != 1 || _nativeSend.length != 1) {
            revert MockRouterUnsupportedRoute();
        }
        // `_nativeSend` dan `msg.value` harus sejalan: router sungguhan membaca jumlah
        // yang didebit dari value saat flag ini menyala, dan dari ERC-20 saat tidak.
        if (_nativeSend[0]) {
            if (msg.value != _amount || _debitToken != address(0)) revert MockRouterUnsupportedRoute();
        } else if (msg.value != 0) {
            revert MockRouterUnsupportedRoute();
        }

        address orderbook = _marketAddresses[0];
        bool isBuy = _isBuy[0];

        // Arah yang diklaim harus cocok dengan pasarnya. Router sungguhan tahu ini dari
        // orderbook-nya; mock ini memeriksanya supaya adapter yang membalik base/quote
        // gagal di sini, bukan diam-diam menukar dengan harga terbalik.
        (,, address base,, address quote,,,,,,) = IKuruOrderBook(orderbook).getMarketParams();
        (address tokenIn, address tokenOut) = isBuy ? (quote, base) : (base, quote);
        if (_debitToken != tokenIn || _creditToken != tokenOut) revert MockRouterUnsupportedRoute();

        uint256 used = (_amount * spendBps) / 10_000;
        uint256 num = priceNum[orderbook];
        uint256 den = priceDen[orderbook];
        _amountOut = isBuy ? (used * den) / num : (used * num) / den;
        _amountOut = (_amountOut * payoutBps) / 10_000;

        if (_amountOut < _minAmountOut) revert MockRouterSlippage();

        if (_debitToken == address(0)) {
            // Native came in with the call. Refund the part a partial fill left over.
            uint256 refund = _amount - used;
            if (refund != 0) _sendNative(msg.sender, refund);
        } else {
            IERC20(_debitToken).transferFrom(msg.sender, address(this), used);
        }

        if (_creditToken == address(0)) {
            _sendNative(msg.sender, _amountOut);
        } else {
            IERC20(_creditToken).transfer(msg.sender, _amountOut);
        }
    }

    function _sendNative(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert MockRouterUnsupportedRoute();
    }

    /// @dev Funded by the test so it can pay out a native leg.
    receive() external payable {}
}
