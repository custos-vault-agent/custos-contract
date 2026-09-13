// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMarket} from "../../src/interfaces/IMarket.sol";

/// @notice Pasar palsu dengan harga tetap, dipakai sampai adapter Kuru siap (langkah 7).
///
/// @dev Sengaja bisa berperilaku buruk. `spendBps` membuatnya hanya memakai sebagian
///      dari yang disetujui, dan `payoutBps` membuatnya memberi lebih atau kurang dari
///      harga wajar — dua perilaku yang justru harus ditangani jalur akuntansi Custos
///      dengan benar (refund allowance, penolakan fill berlebih), dan yang tidak akan
///      pernah muncul dari pasar yang selalu bersikap sempurna.
contract MockMarket is IMarket {
    address public immutable base;
    address public immutable quote;

    /// @dev Harga: `priceNum` unit quote per `priceDen` unit base.
    uint256 public priceNum;
    uint256 public priceDen;

    /// @dev Bagian `amountIn` yang benar-benar dipakai. 10_000 = seluruhnya.
    uint256 public spendBps = 10_000;
    /// @dev Pengali hasil keluar. 10_000 = harga wajar, >10_000 = fill lebih baik.
    uint256 public payoutBps = 10_000;

    error MockSlippage();

    constructor(address base_, address quote_, uint256 priceNum_, uint256 priceDen_) {
        base = base_;
        quote = quote_;
        priceNum = priceNum_;
        priceDen = priceDen_;
    }

    function baseToken() external view returns (address) {
        return base;
    }

    function quoteToken() external view returns (address) {
        return quote;
    }

    function setPrice(uint256 num, uint256 den) external {
        priceNum = num;
        priceDen = den;
    }

    function setSpendBps(uint256 bps) external {
        spendBps = bps;
    }

    function setPayoutBps(uint256 bps) external {
        payoutBps = bps;
    }

    function swap(bool isBuy, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut)
    {
        uint256 used = (amountIn * spendBps) / 10_000;

        (address tokenIn, address tokenOut) = isBuy ? (quote, base) : (base, quote);
        amountOut = isBuy ? (used * priceDen) / priceNum : (used * priceNum) / priceDen;
        amountOut = (amountOut * payoutBps) / 10_000;

        if (amountOut < minAmountOut) revert MockSlippage();

        IERC20(tokenIn).transferFrom(msg.sender, address(this), used);
        IERC20(tokenOut).transfer(msg.sender, amountOut);
    }
}
