// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CustosCore} from "../../src/CustosCore.sol";

/// @notice Aurora Receiver palsu. Aurora Intents Connect cuma menyediakan widget dan
///         API untuk mainnet — belum ada endpoint testnet nyata untuk dites, jadi
///         kontrak ini menempati posisi yang sama seperti Aurora Receiver asli:
///         di-allowlist lewat `setAuroraReceiver`, dan satu-satunya pemanggil yang
///         dipercaya `creditDeposit`.
///
/// @dev Yang ditiru bukan solver lintas-chain-nya (itu sepenuhnya di luar kendali
///      Custos) — hanya *hasil akhirnya*: dana sudah mendarat di rantai tujuan dalam
///      bentuk `accountingAsset`, siap dikreditkan ke satu vault. `fulfillIntent`
///      menarik dana itu dari `msg.sender` lalu meneruskannya persis seperti Aurora
///      Receiver asli akan lakukan begitu solver-nya selesai — supaya jalur
///      `creditDeposit` bisa didemokan dan diuji utuh tanpa menunggu integrasi
///      Aurora yang sebenarnya.
contract MockAuroraReceiver {
    using SafeERC20 for IERC20;

    CustosCore public immutable custos;
    IERC20 public immutable accountingAsset;

    constructor(CustosCore custos_, IERC20 accountingAsset_) {
        custos = custos_;
        accountingAsset = accountingAsset_;
    }

    /// @notice Simulasi intent yang sudah selesai: pemanggil sudah "memegang" dana
    ///         hasil bridge+swap lintas-chain, dan panggilan ini mengkreditkannya ke
    ///         vault agent yang dituju.
    function fulfillIntent(bytes32 agentId, address subscriber, uint256 assets)
        external
        returns (uint256 shares)
    {
        accountingAsset.safeTransferFrom(msg.sender, address(this), assets);
        accountingAsset.forceApprove(address(custos), assets);
        shares = custos.creditDeposit(agentId, subscriber, assets);
    }
}
