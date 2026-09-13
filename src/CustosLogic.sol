// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TradeModule} from "./modules/TradeModule.sol";
import {VaultModule} from "./modules/VaultModule.sol";

/// @title Custos — kustodi dan registry agent untuk trading lintas rantai di Kuru.
///
/// @notice Satu kontrak implementation yang menyusun empat modul. Bukan Diamond: pada
///         skala ini pemisahan lewat `abstract contract` memberi keterbacaan yang sama
///         tanpa router selector, tanpa storage layout kedua, dan tanpa satu pun
///         `delegatecall` tambahan di jalur panas.
///
/// @dev Seluruh state hidup di namespace ERC-7201 (`custos.storage.*`), bukan di slot
///      berurutan. Upgrade karena itu tidak pernah bisa menggeser field: modul boleh
///      ditambah, urutan pewarisan boleh diubah, dan saldo tetap di tempatnya. Itulah
///      satu-satunya alasan arsitektur ini dipilih.
///
///      Aturan yang menjaga seluruhnya: **identitas tidak pernah datang dari calldata.**
///      Satu-satunya pengecualian adalah `creditDeposit`, yang dijaga allowlist Aurora
///      Receiver.
contract CustosLogic is VaultModule, TradeModule {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Implementation tidak boleh bisa di-initialize sendiri: storage-nya kosong,
        // jadi `upgradeAuthority` di sana adalah address(0) dan siapa pun bisa
        // mengklaimnya, lalu meng-upgrade implementation itu ke kontrak dengan
        // `selfdestruct`. Proxy-nya ikut mati bersamanya.
        _disableInitializers();
    }

    function initialize(address upgradeAuthority_, address accountingAsset_) external initializer {
        __AccessControl_init(upgradeAuthority_, accountingAsset_);
    }

    function version() external pure virtual returns (string memory) {
        return "1.0.0";
    }
}
