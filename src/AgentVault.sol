// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Status} from "./Types.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {IYieldSource} from "./interfaces/IYieldSource.sol";
import {
    AgentCannotCallThis,
    AllowanceExceeded,
    MarketNotAllowed,
    OnlyAgent,
    OnlyCustosCore,
    SlippageExceeded,
    VaultNotActive,
    YieldWithdrawFailed,
    ZeroAddress,
    ZeroAmount
} from "./Errors.sol";
import {
    AgentPeriodRolled,
    CircuitBreakerTriggered,
    FeeMinted,
    SeedDeposited,
    SubscriberDeposited,
    SubscriberRedeemed,
    SwapExecuted,
    YieldPulled,
    YieldPushed
} from "./Events.sol";

/// @notice Satu vault ERC-4626 per agent (spec v1 D13). Immutable setelah deploy —
///         bukan proxy, jadi upgrade CustosCore tidak pernah bisa menyentuhnya.
///
/// @dev Storage biasa, bukan ERC-7201: namespace hanya perlu dijaga stabil lintas
///      *upgrade*, dan kontrak ini tidak pernah di-upgrade sama sekali.
///
///      Identitas trading tidak pernah ambigu di sini seperti di CustosCore v0.1:
///      `agent` adalah satu alamat tetap, diperiksa langsung lewat `onlyAgent`. Tidak
///      ada resolusi "wallet ini mewakili siapa" — vault ini hanya punya satu agent.
contract AgentVault is ERC4626, ReentrancyGuard {
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    /* ---------------------------- immutables ------------------------------ */

    address public immutable creator;
    address public immutable agent;
    address public immutable custosCore;
    address public immutable marketAdapter;
    /// @dev Dibutuhkan supaya `SwapExecuted` bisa meng-index `agentId` (spec §7) —
    ///      tanpa ini vault tidak punya cara tahu id-nya sendiri di registry.
    bytes32 public immutable agentId;
    uint16 public immutable feeRate;
    uint16 public immutable maxDrawdownBps;
    address public immutable yieldSource;
    uint16 public immutable maxUtilizationBps;

    /* ----------------------------- mutable state --------------------------- */

    Status public status;

    /// @dev Share price tertinggi yang pernah dicapai, scaled 1e18 (D14). Hanya bisa
    ///      naik, kecuali satu pengecualian eksplisit: reset saat `resumeAgent`
    ///      setelah circuit breaker.
    uint256 public highWaterMark;

    uint128 public allowance;
    uint128 public usedInPeriod;
    uint64 public periodStart;
    uint32 public periodLength;

    mapping(address market => bool allowed) public allowedMarkets;

    /* ------------------------------ modifiers ------------------------------ */

    modifier onlyAgent() {
        if (msg.sender != agent) revert OnlyAgent();
        _;
    }

    modifier onlyCustosCore() {
        if (msg.sender != custosCore) revert OnlyCustosCore();
        _;
    }

    modifier whenActive() {
        if (status != Status.Active) revert VaultNotActive();
        _;
    }

    constructor(
        bytes32 agentId_,
        address creator_,
        address agent_,
        address custosCore_,
        address asset_,
        address marketAdapter_,
        address yieldSource_,
        uint16 feeRate_,
        uint16 maxDrawdownBps_,
        uint16 maxUtilizationBps_,
        uint128 allowance_,
        uint32 periodLength_,
        string memory tokenName_,
        string memory tokenSymbol_
    ) ERC20(tokenName_, tokenSymbol_) ERC4626(IERC20(asset_)) {
        if (
            creator_ == address(0) || agent_ == address(0) || custosCore_ == address(0)
                || marketAdapter_ == address(0) || asset_ == address(0)
        ) revert ZeroAddress();

        agentId = agentId_;
        creator = creator_;
        agent = agent_;
        custosCore = custosCore_;
        marketAdapter = marketAdapter_;
        yieldSource = yieldSource_;
        feeRate = feeRate_;
        maxDrawdownBps = maxDrawdownBps_;
        maxUtilizationBps = maxUtilizationBps_;
        allowance = allowance_;
        periodLength = periodLength_;
        periodStart = uint64(block.timestamp);
        status = Status.Active;
        // Diset di constructor, bukan hanya di `seedDeposit` — sebuah vault yang
        // belum pernah disetor tetap harus punya harga acuan 1:1, supaya
        // `_chargeFeeIfProfit` tidak salah membaca share price pertama (> 0) sebagai
        // "profit" di atas high water mark yang masih nol.
        highWaterMark = 1e18;
    }

    /* ------------------------- subscriber-facing --------------------------- */

    /// @notice Total dana yang dikontrol vault — idle balance + posisi di yield
    ///         source. Share price bergerak otomatis setiap kali angka ini berubah,
    ///         baik dari swap, akrual yield, maupun deposit/redeem.
    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (yieldSource == address(0)) return idle;
        return idle + IYieldSource(yieldSource).balanceOf(address(this));
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256 shares) {
        if (msg.sender == agent) revert AgentCannotCallThis();
        if (status != Status.Active) revert VaultNotActive();
        shares = super.deposit(assets, receiver);
        _pushToYield();
        emit SubscriberDeposited(address(this), receiver, assets, shares);
    }

    /// @dev Spec §4.6 hanya menyebut `deposit`/`redeem`/`withdraw` sebagai override,
    ///      tapi `mint` adalah pintu masuk ERC-4626 yang sama (menyatakan shares,
    ///      bukan assets) — membiarkannya tanpa guard akan diam-diam melewati status
    ///      Active dan push-to-yield yang justru jadi alasan `deposit` di-override.
    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256 assets) {
        if (msg.sender == agent) revert AgentCannotCallThis();
        if (status != Status.Active) revert VaultNotActive();
        assets = super.mint(shares, receiver);
        _pushToYield();
        emit SubscriberDeposited(address(this), receiver, assets, shares);
    }

    /// @dev Tidak ada status check (D19) — redeem selalu bisa, bahkan saat
    ///      paused/revoked. Fee di-charge sebelum redeem supaya subscriber yang
    ///      keluar tidak membawa bagian profit yang seharusnya milik creator.
    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        if (msg.sender == agent) revert AgentCannotCallThis();
        _chargeFeeIfProfit();
        assets = previewRedeem(shares);
        _pullFromYield(assets);
        assets = super.redeem(shares, receiver, owner_);
        emit SubscriberRedeemed(address(this), receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        if (msg.sender == agent) revert AgentCannotCallThis();
        _chargeFeeIfProfit();
        _pullFromYield(assets);
        shares = super.withdraw(assets, receiver, owner_);
        emit SubscriberRedeemed(address(this), receiver, assets, shares);
    }

    /// @dev D20: agent wallet balance di share token harus selalu nol. `transfer`
    ///      diblokir untuk agent supaya poin ini benar bahkan kalau suatu saat agent
    ///      menerima share lewat jalur lain (mis. airdrop paksa dari luar sistem).
    function transfer(address to, uint256 amount) public override(ERC20, IERC20) returns (bool) {
        if (msg.sender == agent) revert AgentCannotCallThis();
        return super.transfer(to, amount);
    }

    function approve(address spender, uint256 amount) public override(ERC20, IERC20) returns (bool) {
        if (msg.sender == agent) revert AgentCannotCallThis();
        return super.approve(spender, amount);
    }

    function transferFrom(address from, address to, uint256 amount)
        public
        override(ERC20, IERC20)
        returns (bool)
    {
        if (msg.sender == agent) revert AgentCannotCallThis();
        return super.transferFrom(from, to, amount);
    }

    /* --------------------------- creator-facing ----------------------------- */

    /// @notice Mengubah status vault. Resume dari Paused ke Active juga mereset
    ///         `highWaterMark` ke share price saat ini (D21) — satu-satunya cara
    ///         `highWaterMark` bisa turun, dan hanya lewat panggilan eksplisit ini.
    ///         Tanpa reset, swap berikutnya langsung memicu breaker lagi karena
    ///         share price masih di bawah level lama.
    function setStatus(Status newStatus) external onlyCustosCore {
        if (newStatus == Status.Active && status == Status.Paused) {
            uint256 supply = totalSupply();
            highWaterMark = supply == 0 ? 1e18 : (totalAssets() * 1e18) / supply;
        }
        status = newStatus;
    }

    function setAllowance(uint128 newAllowance) external onlyCustosCore {
        allowance = newAllowance;
    }

    function setPeriod(uint32 newPeriodLength) external onlyCustosCore {
        _rollPeriod();
        periodLength = newPeriodLength;
        periodStart = uint64(block.timestamp);
    }

    function setMarketAllowed(address market, bool allowed) external onlyCustosCore {
        allowedMarkets[market] = allowed;
    }

    /// @notice Setoran pertama vault, dipanggil sekali oleh CustosCore tepat setelah
    ///         deploy. Shares dikirim ke `address(1)` (dead address) dan terkunci
    ///         permanen — inilah pertahanan D15 terhadap ERC-4626 inflation attack,
    ///         dan sinyal skin-in-the-game creator ke subscriber.
    /// @dev Dana sudah ditransfer ke vault oleh CustosCore sebelum panggilan ini
    ///      (pola yang sama seperti v0.1's `creditDeposit`: ukur, jangan percaya
    ///      klaim pemanggil) — jadi fungsi ini hanya mencatat, tidak menarik apa pun.
    function seedDeposit(uint128 amount) external onlyCustosCore {
        uint256 shares = amount; // harga awal 1:1
        _mint(address(1), shares);
        // `highWaterMark` sudah 1e18 sejak constructor — tidak perlu diset ulang di sini.
        _pushToYield();
        emit SeedDeposited(address(this), creator, amount, shares, address(1));
    }

    /* -------------------------- agent-facing: trading ------------------------ */

    /// @param isBuy True: `amountIn` dalam accounting asset (USDC), hasil dalam base.
    ///        False: kebalikannya.
    /// @param maxNotional Batas notional untuk sisi sell. Diabaikan pada buy — di
    ///        sana `amountIn` sudah jadi batasnya. Wajib > 0 pada sell: berbeda dari
    ///        v0.1, tidak ada lagi "owner bertindak langsung" yang butuh fallback
    ///        tak terbatas — `executeSwap` di sini hanya pernah dipanggil `agent`.
    function executeSwap(address market, bool isBuy, uint128 amountIn, uint128 minAmountOut, uint128 maxNotional)
        external
        onlyAgent
        whenActive
        nonReentrant
        returns (uint128 notionalCharged)
    {
        if (amountIn == 0) revert ZeroAmount();
        if (!allowedMarkets[market]) revert MarketNotAllowed();

        uint128 notionalMax;
        if (isBuy) {
            notionalMax = amountIn;
        } else {
            if (maxNotional == 0) revert ZeroAmount();
            notionalMax = maxNotional;
        }

        _rollPeriod();

        // D24 — agent tidak boleh melebihi allowance *maupun* utilization cap; yang
        // lebih kecil yang berlaku. Sisa dana selalu tersedia untuk subscriber redeem.
        uint256 maxTradable = (totalAssets() * maxUtilizationBps) / 10_000;
        uint256 effectiveAllowance = uint256(allowance) < maxTradable ? allowance : maxTradable;
        uint256 committed = usedInPeriod;
        if (committed + notionalMax > effectiveAllowance) {
            uint256 headroom = committed >= effectiveAllowance ? 0 : effectiveAllowance - committed;
            revert AllowanceExceeded(headroom);
        }
        usedInPeriod += notionalMax;

        // Vault selalu mencoba idle balance dulu, baru tarik dari yield (D22).
        _pullFromYield(amountIn);

        (uint128 baseAmount, uint128 quoteAmount) = _swapAndSettle(market, isBuy, amountIn, minAmountOut);

        notionalCharged = quoteAmount;
        if (notionalCharged > notionalMax) revert SlippageExceeded();
        usedInPeriod -= (notionalMax - notionalCharged);

        _chargeFeeIfProfit();
        // Cek dijalankan setelah fee mint, supaya highWaterMark yang dipakai sudah
        // yang terbaru (D21). Swap yang memicu breaker tetap tereksekusi — dana
        // sudah bergerak — tapi push-to-yield di-skip: biarkan dana idle supaya
        // subscriber bisa redeem cepat tanpa menunggu withdraw dari yield source (I11).
        bool tripped = _checkCircuitBreaker();
        if (!tripped) _pushToYield();

        uint256 supply = totalSupply();
        emit SwapExecuted(
            address(this),
            agentId,
            market,
            isBuy,
            baseAmount,
            quoteAmount,
            notionalCharged,
            totalAssets(),
            supply == 0 ? 0 : (totalAssets() * 1e18) / supply
        );
    }

    /// @dev Dipisahkan dari `executeSwap` karena keduanya bersama-sama melampaui
    ///      batas 16 slot stack solc — kendala yang sama yang sudah memecah v0.1's
    ///      `TradeModule.executeSwap` dan `KuruMarketAdapter.swap`.
    function _swapAndSettle(address market, bool isBuy, uint128 amountIn, uint128 minAmountOut)
        internal
        returns (uint128 baseAmount, uint128 quoteAmount)
    {
        address quoteToken = asset();
        address baseToken = IMarket(market).baseToken();
        (address tokenIn, address tokenOut) = isBuy ? (quoteToken, baseToken) : (baseToken, quoteToken);

        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        IERC20(tokenIn).forceApprove(market, amountIn);
        IMarket(market).swap(isBuy, amountIn, minAmountOut);
        IERC20(tokenIn).forceApprove(market, 0);

        uint256 spent = inBefore - IERC20(tokenIn).balanceOf(address(this));
        uint256 received = IERC20(tokenOut).balanceOf(address(this)) - outBefore;

        return isBuy ? (received.toUint128(), spent.toUint128()) : (spent.toUint128(), received.toUint128());
    }

    /* -------------------------- internal: period ---------------------------- */

    /// @dev Sama seperti v0.1 `Accounting._rollPeriod`, dipindah ke sini karena tidak
    ///      ada lagi modul dasar bersama untuk banyak agent — satu vault = satu agent.
    function _rollPeriod() internal {
        if (periodLength == 0) return;
        uint256 elapsed = block.timestamp - periodStart;
        if (elapsed < periodLength) return;

        uint128 usedBefore = usedInPeriod;
        // forge-lint: disable-next-line(divide-before-multiply)
        periodStart = uint64(uint256(periodStart) + (elapsed / periodLength) * periodLength);
        usedInPeriod = 0;
        emit AgentPeriodRolled(agentId, periodStart, usedBefore);
    }

    /* --------------------------- internal: yield ---------------------------- */

    /// @dev No-op kalau yieldSource == address(0) (pure trading vault, D22).
    function _pushToYield() internal {
        if (yieldSource == address(0)) return;
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle == 0) return;
        IERC20(asset()).forceApprove(yieldSource, idle);
        IYieldSource(yieldSource).deposit(idle);
        emit YieldPushed(address(this), idle);
    }

    /// @dev No-op kalau idle balance sudah cukup, atau yield disabled.
    function _pullFromYield(uint256 needed) internal {
        if (yieldSource == address(0)) return;
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle >= needed) return;

        uint256 deficit = needed - idle;
        uint256 available = IYieldSource(yieldSource).balanceOf(address(this));
        uint256 toWithdraw = deficit > available ? available : deficit;
        if (toWithdraw == 0) return;

        uint256 withdrawn = IYieldSource(yieldSource).withdraw(toWithdraw);
        if (withdrawn == 0) revert YieldWithdrawFailed();
        emit YieldPulled(address(this), withdrawn);
    }

    /* ---------------------------- internal: fee ------------------------------ */

    /// @notice Mint fee shares ke creator kalau share price sudah melewati high water
    ///         mark (D14). Dipanggil sebelum setiap redeem dan setelah setiap swap
    ///         yang profit (Task 9 menyambungkan sisi swap-nya).
    function _chargeFeeIfProfit() internal {
        uint256 supply = totalSupply();
        if (supply == 0) return;

        uint256 currentSharePrice = (totalAssets() * 1e18) / supply;
        if (currentSharePrice <= highWaterMark) return;

        uint256 profitPerShare = currentSharePrice - highWaterMark;
        uint256 totalProfit = (profitPerShare * supply) / 1e18;
        uint256 feeAssets = (totalProfit * feeRate) / 10_000;
        uint256 feeShares = convertToShares(feeAssets);

        // Kalau feeAssets membulatkan ke 0 share, jangan majukan highWaterMark —
        // kalau tidak, dust rounding dari redeem kecil berulang bisa mendorong HWM
        // naik tanpa fee yang benar-benar tertagih, membuat profit sekecil apa pun
        // jadi tidak bisa dikenai fee lagi selamanya.
        if (feeShares > 0) {
            _mint(creator, feeShares);
            highWaterMark = (totalAssets() * 1e18) / totalSupply();
        }
        emit FeeMinted(address(this), creator, feeShares, feeAssets, highWaterMark);
    }

    /// @notice Auto-pause saat share price turun melewati `maxDrawdownBps` dari high
    ///         water mark (D21). `maxDrawdownBps == 0` menonaktifkan pengecekan ini
    ///         seluruhnya.
    function _checkCircuitBreaker() internal returns (bool tripped) {
        if (maxDrawdownBps == 0) return false;
        uint256 supply = totalSupply();
        if (supply == 0) return false;

        uint256 currentPrice = (totalAssets() * 1e18) / supply;
        uint256 threshold = (highWaterMark * (10_000 - maxDrawdownBps)) / 10_000;
        if (currentPrice < threshold) {
            status = Status.Paused;
            emit CircuitBreakerTriggered(address(this), currentPrice, highWaterMark, maxDrawdownBps);
            return true;
        }
        return false;
    }
}
