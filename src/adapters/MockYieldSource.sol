// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IYieldSource} from "../interfaces/IYieldSource.sol";
import {ZeroAddress} from "../Errors.sol";

/// @notice Yield source palsu dengan APY tetap, untuk demo hackathon (spec v1 §11 O6)
///         sampai ada lending protocol yang tersedia di Monad.
///
/// @dev Bukan test-only mock — ini adapter yang benar-benar di-deploy untuk demo,
///      makanya hidup di `src/adapters/` bersama `KuruMarketAdapter`, bukan di
///      `test/mocks/`. Test suite memakainya langsung; tidak ada double terpisah.
///
///      Akrual linear sederhana: `balance = principal * (1 + apyBps/10_000 * elapsed/365days)`.
///      Tidak ada compounding — cukup untuk demo, dan linear membuat matematikanya
///      mudah diverifikasi lewat mata di test manapun.
contract MockYieldSource is IYieldSource {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;
    uint256 public immutable apyBps;

    struct Position {
        uint256 principal;
        uint256 depositedAt;
    }

    mapping(address account => Position) internal _positions;

    constructor(address asset_, uint256 apyBps_) {
        if (asset_ == address(0)) revert ZeroAddress();
        asset = IERC20(asset_);
        apyBps = apyBps_;
    }

    function deposit(uint256 assets) external returns (uint256 deposited) {
        // Akrual yang sudah berjalan di-realisasi ke principal dulu sebelum
        // menambah setoran baru, supaya deposit kedua tidak "menimpa" bunga yang
        // sudah terkumpul dari deposit pertama.
        uint256 current = balanceOf(msg.sender);
        asset.safeTransferFrom(msg.sender, address(this), assets);
        _positions[msg.sender] = Position({principal: current + assets, depositedAt: block.timestamp});
        return assets;
    }

    function withdraw(uint256 assets) external returns (uint256 withdrawn) {
        uint256 current = balanceOf(msg.sender);
        withdrawn = assets > current ? current : assets;
        if (withdrawn == 0) return 0;

        _positions[msg.sender] = Position({principal: current - withdrawn, depositedAt: block.timestamp});
        asset.safeTransfer(msg.sender, withdrawn);
    }

    function balanceOf(address account) public view returns (uint256) {
        Position storage p = _positions[account];
        if (p.principal == 0) return 0;

        uint256 elapsed = block.timestamp - p.depositedAt;
        uint256 accrued = (p.principal * apyBps * elapsed) / (10_000 * 365 days);
        return p.principal + accrued;
    }
}
