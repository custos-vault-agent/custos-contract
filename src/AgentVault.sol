// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Status} from "./Types.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {ICustosPaused} from "./interfaces/ICustosPaused.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IYieldSource} from "./interfaces/IYieldSource.sol";
import {
    AgentCannotCallThis,
    AllowanceExceeded,
    MarketNotAllowed,
    OnlyAgent,
    NoPriceFeed,
    OnlyCustosCore,
    OracleQuoteMismatch,
    Paused,
    SlippageExceeded,
    SwapDrawdownExceeded,
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

/// @notice One ERC-4626 vault per agent (spec v1 D13). Immutable after deploy — not a
///         proxy, so upgrading CustosCore can never touch it.
///
/// @dev Plain storage, not ERC-7201: namespacing only matters across upgrades and this
///      contract is never upgraded.
///
///      Trading identity is a single fixed `agent` address checked by `onlyAgent`.
///      There is no "which owner does this wallet act for" resolution here.
contract AgentVault is ERC4626, ReentrancyGuard {
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    /* ---------------------------- immutables ------------------------------ */

    address public immutable creator;
    address public immutable agent;
    address public immutable custosCore;
    /// @dev Values held base tokens (H2). Frozen at deploy; feeds live in PriceOracle.
    address public immutable priceOracle;
    /// @dev Needed so `SwapExecuted` can index `agentId` (spec §7).
    bytes32 public immutable agentId;
    uint16 public immutable feeRate;
    uint16 public immutable maxDrawdownBps;
    address public immutable yieldSource;
    uint16 public immutable maxUtilizationBps;

    /* ----------------------------- mutable state --------------------------- */

    Status public status;

    /// @dev Highest share price reached, scaled 1e18 (D14). Only goes up, except the
    ///      explicit reset on resume after a circuit breaker.
    uint256 public highWaterMark;

    uint128 public allowance;
    uint128 public usedInPeriod;
    uint64 public periodStart;
    uint32 public periodLength;

    mapping(address market => bool allowed) public allowedMarkets;

    /// @dev Base token of every market ever allowed — summed in `totalAssets`.
    ///      Append-only: disallowing a market does not remove its base balance.
    address[] public heldBases;

    /// @dev H3: HWM may only be reset on resume *after* a circuit breaker, never after
    ///      a manual creator pause — otherwise the creator could lower the HWM at will
    ///      and charge fees on a recovery that has not made subscribers whole.
    bool public breakerTripped;

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
        address priceOracle_,
        // address(0) is valid: it disables idle yield entirely (pure trading vault, D22).
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
                || priceOracle_ == address(0) || asset_ == address(0)
        ) revert ZeroAddress();
        if (IPriceOracle(priceOracle_).quoteToken() != asset_) revert OracleQuoteMismatch();

        agentId = agentId_;
        creator = creator_;
        agent = agent_;
        custosCore = custosCore_;
        priceOracle = priceOracle_;
        yieldSource = yieldSource_;
        feeRate = feeRate_;
        maxDrawdownBps = maxDrawdownBps_;
        maxUtilizationBps = maxUtilizationBps_;
        allowance = allowance_;
        periodLength = periodLength_;
        periodStart = uint64(block.timestamp);
        status = Status.Active;
        // Set here, not only in `seedDeposit`, so an unseeded vault still has a 1:1
        // reference and `_chargeFeeIfProfit` never reads the first price as profit.
        highWaterMark = 1e18;
    }

    /* ------------------------- subscriber-facing --------------------------- */

    /// @notice Total assets under vault control: idle balance + yield position + held
    ///         base tokens valued by the oracle (H2). Share price follows this number.
    /// @dev Reverts if a held base's feed is stale, which also blocks deposit/redeem/
    ///      swap until the feed recovers — deliberate: halt rather than value a
    ///      position at a stale price.
    function totalAssets() public view override returns (uint256 total) {
        total = IERC20(asset()).balanceOf(address(this));
        if (yieldSource != address(0)) total += IYieldSource(yieldSource).balanceOf(address(this));
        uint256 n = heldBases.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 bal = IERC20(heldBases[i]).balanceOf(address(this));
            if (bal != 0) total += IPriceOracle(priceOracle).valueOf(heldBases[i], bal);
        }
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256 shares) {
        // L5: shares sent to the agent could never be moved or redeemed.
        if (msg.sender == agent || receiver == agent) revert AgentCannotCallThis();
        if (status != Status.Active) revert VaultNotActive();
        shares = super.deposit(assets, receiver);
        _pushToYield();
        // Emitted after the external call because it needs `shares`; nonReentrant
        // covers it. Same reasoning for every event-after-call in this file.
        emit SubscriberDeposited(address(this), receiver, assets, shares);
    }

    /// @dev `mint` is the same ERC-4626 entry as `deposit` (shares-denominated);
    ///      leaving it unguarded would bypass the status check and push-to-yield.
    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256 assets) {
        if (msg.sender == agent || receiver == agent) revert AgentCannotCallThis();
        if (status != Status.Active) revert VaultNotActive();
        assets = super.mint(shares, receiver);
        _pushToYield();
        emit SubscriberDeposited(address(this), receiver, assets, shares);
    }

    /// @notice L4: `redeem` and `withdraw` charge the performance fee first, which
    ///         mints shares to the creator and dilutes the caller. These previews
    ///         count that mint, so `previewRedeem` never promises more assets than
    ///         `redeem` pays, and `previewWithdraw` never promises fewer shares than
    ///         `withdraw` burns (EIP-4626). `previewDeposit` and `previewMint` need
    ///         no override: a deposit charges no fee.
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return Math.mulDiv(shares, totalAssets() + 1, _supplyAfterFee(), Math.Rounding.Floor);
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        return Math.mulDiv(assets, _supplyAfterFee(), totalAssets() + 1, Math.Rounding.Ceil);
    }

    /// @dev The denominator ERC-4626 would use after `_chargeFeeIfProfit` runs.
    function _supplyAfterFee() internal view returns (uint256) {
        return totalSupply() + _pendingFeeShares() + 10 ** _decimalsOffset();
    }

    /// @dev Shares that `_chargeFeeIfProfit` would mint right now. Same arithmetic,
    ///      without the state change.
    function _pendingFeeShares() internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        uint256 assets = totalAssets();
        if ((assets * 1e18) / supply <= highWaterMark) return 0;
        uint256 totalProfit = assets - (highWaterMark * supply) / 1e18;
        return convertToShares((totalProfit * feeRate) / 10_000);
    }

    /// @dev No status check (D19): redeem always works, even when paused/revoked.
    ///      Fee is charged first so a leaving subscriber does not take the creator's
    ///      share of profit with them.
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

    /// @dev D20: the agent's share balance must stay zero. Blocking `transfer` keeps
    ///      that true even if shares reach the agent some other way.
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

    /// @notice Sets vault status. Resuming *after a circuit breaker* also resets
    ///         `highWaterMark` to the current share price (D21) — the only way it can
    ///         go down. Without the reset the next swap would trip the breaker again.
    ///         A manual creator pause followed by resume does NOT reset (H3).
    function setStatus(Status newStatus) external onlyCustosCore {
        if (newStatus == Status.Active && breakerTripped) {
            breakerTripped = false;
            uint256 supply = totalSupply();
            // The transition itself is logged upstream (AgentStatusChanged).
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
        if (!allowed) return;
        address base = IMarket(market).baseToken();
        // H2: a base the vault may hold must be priceable first.
        if (!IPriceOracle(priceOracle).hasFeed(base)) revert NoPriceFeed();
        uint256 n = heldBases.length;
        for (uint256 i = 0; i < n; i++) {
            if (heldBases[i] == base) return;
        }
        // ponytail: linear scan; markets per vault are few (protocol-allowlisted).
        heldBases.push(base);
    }

    /// @notice First deposit, called once by CustosCore right after deploy. Shares go
    ///         to `address(1)` and are locked forever — the D15 defence against the
    ///         ERC-4626 inflation attack, and the creator's skin in the game.
    /// @dev Funds were already transferred by CustosCore; this only records them.
    function seedDeposit(uint128 amount) external onlyCustosCore {
        uint256 shares = amount; // initial price 1:1
        _mint(address(1), shares);
        _pushToYield();
        emit SeedDeposited(address(this), creator, amount, shares, address(1));
    }

    /* -------------------------- agent-facing: trading ------------------------ */

    /// @param isBuy True: `amountIn` is accounting asset (USDC), output is base.
    ///        False: the reverse.
    /// @param maxNotional Notional cap for the sell side; ignored on buy where
    ///        `amountIn` already is the cap. Must be > 0 on sell.
    function executeSwap(
        address market,
        bool isBuy,
        uint128 amountIn,
        uint128 minAmountOut,
        uint128 maxNotional
    ) external nonReentrant onlyAgent whenActive returns (uint128 notionalCharged) {
        if (amountIn == 0) revert ZeroAmount();
        if (!allowedMarkets[market]) revert MarketNotAllowed();
        // M4: the protocol-wide pause also stops trading, not only registrations.
        if (ICustosPaused(custosCore).paused()) revert Paused();

        uint128 notionalMax;
        if (isBuy) {
            notionalMax = amountIn;
        } else {
            if (maxNotional == 0) revert ZeroAmount();
            notionalMax = maxNotional;
        }

        _rollPeriod();

        // D24: the smaller of allowance and utilization cap applies, so the remainder
        // is always available for subscriber redemptions.
        uint256 maxTradable = (totalAssets() * maxUtilizationBps) / 10_000;
        uint256 effectiveAllowance = uint256(allowance) < maxTradable ? allowance : maxTradable;
        uint256 committed = usedInPeriod;
        if (committed + notionalMax > effectiveAllowance) {
            uint256 headroom = committed >= effectiveAllowance ? 0 : effectiveAllowance - committed;
            revert AllowanceExceeded(headroom);
        }
        usedInPeriod += notionalMax;

        // L2: only a buy spends the accounting asset; a sell needs no idle USDC.
        if (isBuy) _pullFromYield(amountIn);

        uint256 priceBefore = _sharePrice();
        (uint128 baseAmount, uint128 quoteAmount) = _swapAndSettle(market, isBuy, amountIn, minAmountOut);

        notionalCharged = quoteAmount;
        if (notionalCharged > notionalMax) revert SlippageExceeded();
        usedInPeriod -= (notionalMax - notionalCharged);

        // M1: a single swap may not lose more than maxDrawdownBps on its own. The
        // breaker below still handles the cumulative case against the HWM.
        if (maxDrawdownBps != 0 && _sharePrice() < (priceBefore * (10_000 - maxDrawdownBps)) / 10_000) {
            revert SwapDrawdownExceeded();
        }

        _chargeFeeIfProfit();
        // Checked after the fee mint so the HWM is current (D21). A swap that trips
        // the breaker still executes, but push-to-yield is skipped so funds stay
        // idle for fast redemptions (I11).
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

    /// @dev Split from `executeSwap` to stay under solc's 16-slot stack limit.
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
        // Return value ignored on purpose: spent/received are measured from balance
        // deltas, not trusted from the market.
        IMarket(market).swap(isBuy, amountIn, minAmountOut);
        IERC20(tokenIn).forceApprove(market, 0);

        uint256 spent = inBefore - IERC20(tokenIn).balanceOf(address(this));
        uint256 received = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        // M2: enforced here too, not only by the market.
        if (received < minAmountOut) revert SlippageExceeded();

        return isBuy ? (received.toUint128(), spent.toUint128()) : (spent.toUint128(), received.toUint128());
    }

    /// @dev 1e18-scaled; 1e18 for an empty vault.
    function _sharePrice() internal view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? 1e18 : (totalAssets() * 1e18) / supply;
    }

    /* -------------------------- internal: period ---------------------------- */

    function _rollPeriod() internal {
        if (periodLength == 0) return;
        // periodLength is hours/days; seconds of validator timestamp drift are immaterial.
        uint256 elapsed = block.timestamp - periodStart;
        if (elapsed < periodLength) return;

        uint128 usedBefore = usedInPeriod;
        // forge-lint: disable-next-line(divide-before-multiply)
        periodStart = uint64(uint256(periodStart) + (elapsed / periodLength) * periodLength);
        usedInPeriod = 0;
        emit AgentPeriodRolled(agentId, periodStart, usedBefore);
    }

    /* --------------------------- internal: yield ---------------------------- */

    /// @dev No-op when yieldSource == address(0) (pure trading vault, D22).
    function _pushToYield() internal {
        if (yieldSource == address(0)) return;
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle == 0) return;
        IERC20(asset()).forceApprove(yieldSource, idle);
        IYieldSource(yieldSource).deposit(idle);
        emit YieldPushed(address(this), idle);
    }

    /// @dev No-op when idle balance already covers `needed`, or yield is disabled.
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

    /// @notice Mints fee shares to the creator when share price exceeds the high
    ///         water mark (D14). Called before every redeem and after every swap.
    function _chargeFeeIfProfit() internal {
        uint256 supply = totalSupply();
        if (supply == 0) return;

        uint256 assets = totalAssets();
        uint256 currentSharePrice = (assets * 1e18) / supply;
        if (currentSharePrice <= highWaterMark) return;

        // Single division: (price - hwm) * supply / 1e18 reduces exactly to
        // assets - hwm * supply / 1e18, so rounding loss is at most 1 unit instead
        // of scaling with supply. Cannot underflow given the guard above.
        uint256 totalProfit = assets - (highWaterMark * supply) / 1e18;
        uint256 feeAssets = (totalProfit * feeRate) / 10_000;
        uint256 feeShares = convertToShares(feeAssets);

        // Do not advance the HWM when the fee rounds to 0 shares, or repeated dust
        // redeems could push it up with no fee ever collected.
        if (feeShares > 0) {
            _mint(creator, feeShares);
            // `assets` is unchanged by minting; only totalSupply() moved.
            highWaterMark = (assets * 1e18) / totalSupply();
        }
        emit FeeMinted(address(this), creator, feeShares, feeAssets, highWaterMark);
    }

    /// @notice Auto-pause when share price falls more than `maxDrawdownBps` below the
    ///         high water mark (D21). `maxDrawdownBps == 0` disables the check.
    function _checkCircuitBreaker() internal returns (bool tripped) {
        if (maxDrawdownBps == 0) return false;
        uint256 supply = totalSupply();
        if (supply == 0) return false;

        uint256 currentPrice = (totalAssets() * 1e18) / supply;
        uint256 threshold = (highWaterMark * (10_000 - maxDrawdownBps)) / 10_000;
        if (currentPrice < threshold) {
            status = Status.Paused;
            breakerTripped = true;
            emit CircuitBreakerTriggered(address(this), currentPrice, highWaterMark, maxDrawdownBps);
            return true;
        }
        return false;
    }
}
