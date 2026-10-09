// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {
    IOracleAdapter,
    IDexAdapter,
    IMarketClock,
    IPriceHistory,
    IComplianceRegistry,
    ISignalEngine,
    IAllocator
} from "../interfaces/IGoldbench.sol";

/// @title RotationVault
/// @notice ERC-4626 vault (stablecoin in, stablecoin out) that rotates between a tokenized-stock basket (risk-on) and
///         tokenized gold + T-bills (risk-off) following SignalEngine. Each vault has an immutable stock cap.
///
///  Pricing:   NAV uses OracleAdapter prices. Any state-changing entry (deposit/mint/withdraw/redeem/rebalance) first
///             runs a *strict* valuation that reverts on stale prices, a stablecoin depeg, or a price that deviates
///             more than `navDeviationBps` from the last recorded daily close - so nobody can enter or exit at a
///             manipulated or stale NAV. `totalAssets()` (view) falls back to last closes so UIs never break.
///  Liquidity: cash withdrawals are limited to idle stablecoin; `redeemInKind` always returns a pro-rata slice of
///             every holding and works even while paused.
///  Rebalance: keeper-only, at most once per `rebalanceInterval` (>= 7 days), only during US market hours, executed in
///             `chunkCount` TWAP chunks with oracle-derived min-out and deadlines. Buys of stock assets are clipped so
///             stock value never exceeds `stockCapBps` of NAV at the moment of trading.
///  Fees:      management fee only, accrued by minting shares to FeeCollector, hard-capped at 0.75%/yr in code.
contract RotationVault is
    ERC4626Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    // ----------------------------- constants -----------------------------

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant ACTION_DEPOSIT = keccak256("DEPOSIT");
    bytes32 public constant ACTION_TRANSFER = keccak256("TRANSFER");
    bytes32 public constant ACTION_WITHDRAW = keccak256("WITHDRAW");

    uint16 public constant MAX_MGMT_FEE_BPS = 75; // 0.75 %/yr hard cap
    uint256 public constant MIN_REBALANCE_INTERVAL = 7 days;
    uint256 public constant MAX_HOLDINGS = 8;
    uint256 public constant PLAN_TTL = 3 days;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant DEPEG_BAND = 3e16; // +/-3 %
    /// @dev A swap needs well under this; below it a caught out-of-gas would silently skip a trade, so revert instead.
    uint256 public constant MIN_SWAP_GAS = 400_000;

    // ----------------------------- types -----------------------------

    struct Modules {
        ISignalEngine engine;
        IAllocator allocator;
        IDexAdapter dex;
        IMarketClock clock;
        IOracleAdapter oracle;
        IPriceHistory history;
        address feeCollector;
        IComplianceRegistry compliance; // address(0) = no gating
    }

    struct InitParams {
        string name;
        string symbol;
        IERC20 base;
        uint16 stockCapBps;
        address admin;
        address guardian;
        address keeper;
        uint256 depositCap;
        Modules modules;
    }

    struct Plan {
        bool active;
        uint8 chunksDone;
        uint8 chunksTotal;
        uint64 lastChunkAt;
        uint64 expiresAt;
    }

    // ----------------------------- storage -----------------------------

    Modules public modules;
    uint16 public stockCapBps;
    uint16 public mgmtFeeBps;
    uint16 public bufferBps;
    uint16 public maxSlippageBps;
    uint16 public navDeviationBps;
    uint8 public chunkCount;
    uint32 public chunkInterval;
    uint32 public rebalanceInterval;
    uint64 public lastFeeAccrual;
    uint64 public lastRebalanceStart;
    uint256 public depositCap;
    uint256 public minTradeValue;
    uint256 public rebalanceId;
    Plan public plan;

    address[] internal _holdings;
    mapping(address => bool) public isHolding;
    mapping(address => bool) public isStockAsset;
    mapping(address => uint8) public assetDecimals;
    mapping(address => uint16) public targetBps;

    // ----------------------------- events -----------------------------

    event FeeAccrued(uint256 feeShares, uint256 elapsed);
    event RebalanceStarted(
        uint256 indexed id, ISignalEngine.Signal signal, address[] assets, uint16[] targetBps, uint256 nav
    );
    event ChunkExecuted(uint256 indexed id, uint8 chunk, uint8 chunksTotal, uint256 navBefore);
    event RebalanceCompleted(uint256 indexed id, uint256 nav, uint256 stockValue);
    event RebalanceCancelled(uint256 indexed id);
    event RebalanceExpired(uint256 indexed id);
    event Trade(uint256 indexed id, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event TradeFailed(uint256 indexed id, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, bytes reason);
    event RedeemedInKind(address indexed owner, address indexed receiver, uint256 shares, address[] tokens, uint256[] amounts);
    event HoldingAdded(address indexed asset, bool isStock);
    event ConfigUpdated(bytes32 indexed key, uint256 value);
    event ModuleUpdated(bytes32 indexed key, address value);

    // ----------------------------- errors -----------------------------

    error ZeroAddress();
    error OutOfBounds(uint256 value, uint256 min, uint256 max);
    error MarketClosed();
    error TooSoon(uint256 nextAllowed);
    error RebalanceActive();
    error NoActivePlan();
    error ChunkTooSoon(uint256 nextAllowed);
    error Expired();
    error PriceDeviation(address asset, uint256 price, uint256 lastClose);
    error Depeg(uint256 basePrice);
    error NotCompliant(address account, bytes32 action);
    error TooManyHoldings();
    error ZeroShares();
    error InsufficientGas();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata p) external initializer {
        if (address(p.base) == address(0) || p.admin == address(0) || p.modules.feeCollector == address(0)) {
            revert ZeroAddress();
        }
        _checkBounds(p.stockCapBps, 0, BPS);
        __ERC20_init(p.name, p.symbol);
        __ERC4626_init(p.base);
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, p.admin);
        if (p.guardian != address(0)) _grantRole(GUARDIAN_ROLE, p.guardian);
        if (p.keeper != address(0)) _grantRole(KEEPER_ROLE, p.keeper);

        modules = p.modules;
        stockCapBps = p.stockCapBps;
        mgmtFeeBps = MAX_MGMT_FEE_BPS;
        bufferBps = 300;
        maxSlippageBps = 100;
        navDeviationBps = 1000;
        chunkCount = 4;
        chunkInterval = 30 minutes;
        rebalanceInterval = uint32(MIN_REBALANCE_INTERVAL);
        depositCap = p.depositCap;
        minTradeValue = 10 * 10 ** IERC20Metadata(address(p.base)).decimals();
        lastFeeAccrual = uint64(block.timestamp);
    }

    // ============================= ERC-4626 =============================

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6; // virtual shares: inflation/donation attack resistance
    }

    /// @notice Lenient NAV for views: oracle price when valid, otherwise last recorded close.
    function totalAssets() public view override returns (uint256) {
        (uint256 nav,,) = _valuation(false);
        return nav;
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (paused()) return 0;
        uint256 ta = totalAssets();
        return ta >= depositCap ? 0 : depositCap - ta;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return convertToShares(maxDeposit(receiver));
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        if (paused()) return 0;
        return Math.min(super.maxWithdraw(owner), _idle());
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        if (paused()) return 0;
        return Math.min(balanceOf(owner), convertToShares(_idle()));
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant whenNotPaused returns (uint256) {
        _preDeposit(receiver);
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant whenNotPaused returns (uint256) {
        _preDeposit(receiver);
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        _preWithdraw(receiver, owner);
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        _preWithdraw(receiver, owner);
        return super.redeem(shares, receiver, owner);
    }

    /// @notice Exit with a pro-rata slice of every holding. No oracle dependency; available even when paused.
    function redeemInKind(uint256 shares, address receiver, address owner)
        external
        nonReentrant
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        if (shares == 0) revert ZeroShares();
        if (receiver == address(0)) revert ZeroAddress();
        if (receiver != owner) _requireAllowed(receiver, ACTION_WITHDRAW);
        _accrueFee();
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        uint256 supply = totalSupply();
        uint256 n = _holdings.length;
        tokens = new address[](n + 1);
        amounts = new uint256[](n + 1);
        tokens[0] = asset();
        amounts[0] = Math.mulDiv(IERC20(tokens[0]).balanceOf(address(this)), shares, supply);
        for (uint256 i; i < n; ++i) {
            tokens[i + 1] = _holdings[i];
            amounts[i + 1] = Math.mulDiv(IERC20(_holdings[i]).balanceOf(address(this)), shares, supply);
        }
        _burn(owner, shares); // effects before interactions
        emit RedeemedInKind(owner, receiver, shares, tokens, amounts);
        for (uint256 i; i <= n; ++i) {
            if (amounts[i] != 0) IERC20(tokens[i]).safeTransfer(receiver, amounts[i]);
        }
    }

    function _preDeposit(address receiver) internal {
        _requireAllowed(msg.sender, ACTION_DEPOSIT);
        if (receiver != msg.sender) _requireAllowed(receiver, ACTION_DEPOSIT);
        _accrueFee();
        _valuation(true); // reverts on stale / deviating prices
    }

    function _preWithdraw(address receiver, address owner) internal {
        if (receiver != owner) _requireAllowed(receiver, ACTION_WITHDRAW);
        _accrueFee();
        _valuation(true);
    }

    /// @dev Share transfers are compliance-gated (mint/burn and fee distribution excepted).
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && from != modules.feeCollector) {
            _requireAllowed(to, ACTION_TRANSFER);
        }
        super._update(from, to, value);
    }

    function _requireAllowed(address account, bytes32 action) internal view {
        IComplianceRegistry c = modules.compliance;
        if (address(c) != address(0) && !c.isAllowed(account, action)) revert NotCompliant(account, action);
    }

    // ============================= fees =============================

    function accrueFees() external nonReentrant {
        _accrueFee();
    }

    /// @dev Mints shares so that feeShares / (supply + feeShares) = fee * elapsed / year.
    // slither-disable-next-line incorrect-equality
    function _accrueFee() internal {
        uint256 last = lastFeeAccrual;
        if (block.timestamp <= last) return;
        uint256 elapsed = block.timestamp - last;
        lastFeeAccrual = uint64(block.timestamp);
        uint256 supply = totalSupply();
        if (supply == 0 || mgmtFeeBps == 0) return;
        uint256 f = uint256(mgmtFeeBps) * elapsed;
        uint256 denom = BPS * YEAR;
        if (f >= denom) f = denom - 1;
        uint256 feeShares = Math.mulDiv(supply, f, denom - f);
        if (feeShares == 0) return;
        _mint(modules.feeCollector, feeShares);
        emit FeeAccrued(feeShares, elapsed);
    }

    // ============================= valuation =============================

    function _idle() internal view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @return nav total value in base-token units
    /// @return values per-holding value in base units (same order as _holdings)
    /// @return basePrice base stablecoin USD price (1e18)
    // slither-disable-next-line incorrect-equality
    function _valuation(bool strict) internal view returns (uint256 nav, uint256[] memory values, uint256 basePrice) {
        basePrice = _basePrice(strict);
        nav = _idle();
        uint256 n = _holdings.length;
        values = new uint256[](n);
        uint8 baseDec = IERC20Metadata(asset()).decimals();
        for (uint256 i; i < n; ++i) {
            address a = _holdings[i];
            uint256 bal = IERC20(a).balanceOf(address(this));
            if (bal == 0) continue;
            uint256 p = _assetPrice(a, strict);
            values[i] = Math.mulDiv(bal, p * 10 ** baseDec, basePrice * 10 ** assetDecimals[a]);
            nav += values[i];
        }
    }

    // slither-disable-next-line unused-return
    function _basePrice(bool strict) internal view returns (uint256 p) {
        try modules.oracle.getPrice(asset()) returns (uint256 price, uint256) {
            p = price;
        } catch (bytes memory reason) {
            if (strict) _bubble(reason);
            return 1e18;
        }
        if (p + DEPEG_BAND < 1e18 || p > 1e18 + DEPEG_BAND) {
            if (strict) revert Depeg(p);
            return 1e18;
        }
    }

    // slither-disable-next-line unused-return
    function _assetPrice(address a, bool strict) internal view returns (uint256 p) {
        try modules.oracle.getPrice(a) returns (uint256 price, uint256) {
            p = price;
        } catch (bytes memory reason) {
            if (strict) _bubble(reason);
            return modules.history.latestClose(a);
        }
        if (strict) {
            uint256 ref = modules.history.latestClose(a);
            if (ref != 0) {
                uint256 diff = p > ref ? p - ref : ref - p;
                if (diff * BPS > ref * navDeviationBps) revert PriceDeviation(a, p, ref);
            }
        }
    }

    function _bubble(bytes memory reason) internal pure {
        assembly ("memory-safe") {
            revert(add(reason, 32), mload(reason))
        }
    }

    // ============================= rebalancing =============================

    /// @dev Calls only trusted protocol modules (engine/allocator, Timelock-set) and is nonReentrant; plan state is
    ///      committed before the calls, target weights must be written from their results.
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign,unused-return
    function startRebalance() external nonReentrant onlyRole(KEEPER_ROLE) whenNotPaused {
        if (!modules.clock.isOpen(block.timestamp)) revert MarketClosed();
        Plan memory pl = plan;
        if (pl.active && block.timestamp <= pl.expiresAt) revert RebalanceActive();
        uint256 next = uint256(lastRebalanceStart) + rebalanceInterval;
        if (lastRebalanceStart != 0 && block.timestamp < next) revert TooSoon(next);
        _accrueFee();

        // effects before calling out to engine/allocator
        uint256 id = ++rebalanceId;
        lastRebalanceStart = uint64(block.timestamp);
        plan = Plan({
            active: true,
            chunksDone: 0,
            chunksTotal: chunkCount,
            lastChunkAt: 0,
            expiresAt: uint64(block.timestamp + PLAN_TTL)
        });
        uint256 n = _holdings.length;
        for (uint256 i; i < n; ++i) {
            targetBps[_holdings[i]] = 0;
        }

        ISignalEngine.Signal memory s = modules.engine.refreshSignal();
        (address[] memory assets, uint16[] memory w) = modules.allocator.computeTargets(s, stockCapBps, bufferBps);
        (address[] memory basketAssets,) = modules.engine.basket();
        for (uint256 i; i < assets.length; ++i) {
            _ensureHolding(assets[i], i < basketAssets.length);
            targetBps[assets[i]] = w[i];
        }
        (uint256 nav,,) = _valuation(true);
        emit RebalanceStarted(id, s, assets, w, nav);
    }

    function executeChunk(uint256 deadline) external nonReentrant onlyRole(KEEPER_ROLE) whenNotPaused {
        Plan memory pl = plan;
        if (!pl.active) revert NoActivePlan();
        if (block.timestamp > pl.expiresAt) {
            plan.active = false;
            emit RebalanceExpired(rebalanceId);
            return;
        }
        if (block.timestamp > deadline) revert Expired();
        if (!modules.clock.isOpen(block.timestamp)) revert MarketClosed();
        if (pl.lastChunkAt != 0 && block.timestamp < uint256(pl.lastChunkAt) + chunkInterval) {
            revert ChunkTooSoon(uint256(pl.lastChunkAt) + chunkInterval);
        }
        _accrueFee();

        // effects first: chunk bookkeeping is committed before any external swap
        uint8 done = pl.chunksDone + 1;
        uint256 remaining = uint256(pl.chunksTotal) - pl.chunksDone;
        plan.chunksDone = done;
        plan.lastChunkAt = uint64(block.timestamp);
        if (done >= pl.chunksTotal) plan.active = false;

        (uint256 nav, uint256[] memory values, uint256 basePrice) = _valuation(true);
        uint256 id = rebalanceId;
        emit ChunkExecuted(id, done, pl.chunksTotal, nav);

        _sellLeg(id, nav, values, remaining, deadline);
        _buyLeg(id, basePrice, remaining, deadline);

        if (done >= pl.chunksTotal) {
            (uint256 navAfter, uint256[] memory v,) = _valuation(false);
            emit RebalanceCompleted(id, navAfter, _stockValue(v));
        }
    }

    // slither-disable-next-line incorrect-equality
    function _sellLeg(uint256 id, uint256 nav, uint256[] memory values, uint256 remaining, uint256 deadline) internal {
        address base = asset();
        uint256 n = _holdings.length;
        for (uint256 i; i < n; ++i) {
            address a = _holdings[i];
            uint256 target = (nav * targetBps[a]) / BPS;
            if (values[i] <= target) continue;
            uint256 sellValue = (values[i] - target) / remaining;
            if (sellValue == 0 || (sellValue < minTradeValue && remaining > 1)) continue;
            uint256 bal = IERC20(a).balanceOf(address(this));
            uint256 amountIn = Math.mulDiv(bal, sellValue, values[i]);
            uint256 minOut = Math.mulDiv(values[i] - target, BPS - maxSlippageBps, BPS * remaining);
            _swap(id, a, base, amountIn, minOut, deadline);
        }
    }

    struct BuyCtx {
        uint256 id;
        uint256 nav;
        uint256 remaining;
        uint256 deadline;
        uint256 basePrice;
        uint256 spendable;
        uint256 stockRoom;
    }

    function _buyLeg(uint256 id, uint256 basePrice, uint256 remaining, uint256 deadline) internal {
        // re-value after sells so buys use post-sale cash and current holdings
        (uint256 nav, uint256[] memory values,) = _valuation(true);
        BuyCtx memory c = BuyCtx(id, nav, remaining, deadline, basePrice, 0, 0);
        uint256 reserve = (nav * bufferBps) / BPS;
        uint256 idle = _idle();
        c.spendable = idle > reserve ? idle - reserve : 0;
        // haircut the cap by the slippage tolerance: a fill better than oracle can't push stocks over the cap
        uint256 room = (nav * stockCapBps * (BPS - maxSlippageBps)) / (BPS * BPS);
        uint256 stockNow = _stockValue(values);
        c.stockRoom = room > stockNow ? room - stockNow : 0;

        uint256 n = _holdings.length;
        for (uint256 i; i < n && c.spendable != 0; ++i) {
            _maybeBuy(c, _holdings[i], values[i]);
        }
        _trimStockOvershoot(id, deadline);
    }

    /// @dev Hard guarantee behind "allocations never exceed the stock cap": if fills or rounding still left stock value
    ///      above the cap at oracle prices, sell the excess from the largest stock holding in the same chunk.
    // slither-disable-next-line incorrect-equality
    function _trimStockOvershoot(uint256 id, uint256 deadline) internal {
        (uint256 nav, uint256[] memory values,) = _valuation(true);
        uint256 cap = (nav * stockCapBps) / BPS;
        uint256 stocks = _stockValue(values);
        if (stocks <= cap) return;
        uint256 n = _holdings.length;
        uint256 best = 0;
        for (uint256 i = 1; i < n; ++i) {
            if (isStockAsset[_holdings[i]] && (!isStockAsset[_holdings[best]] || values[i] > values[best])) best = i;
        }
        address a = _holdings[best];
        if (!isStockAsset[a] || values[best] == 0) return;
        uint256 excess = Math.min(stocks - cap, values[best]);
        // round the token amount up so the trim always lands at or under the cap
        uint256 amountIn = Math.mulDiv(IERC20(a).balanceOf(address(this)), excess, values[best], Math.Rounding.Ceil);
        _swap(id, a, asset(), amountIn, (excess * (BPS - maxSlippageBps)) / BPS, deadline);
    }

    // slither-disable-next-line incorrect-equality
    function _maybeBuy(BuyCtx memory c, address a, uint256 value) internal {
        uint256 target = (c.nav * targetBps[a]) / BPS;
        if (value >= target) return;
        uint256 buyValue = (target - value) / c.remaining;
        bool stock = isStockAsset[a];
        if (stock) buyValue = Math.min(buyValue, c.stockRoom);
        buyValue = Math.min(buyValue, c.spendable);
        if (buyValue == 0 || (buyValue < minTradeValue && c.remaining > 1)) return;
        if (_buy(c.id, a, buyValue, c.basePrice, c.deadline)) {
            c.spendable -= buyValue;
            if (stock) c.stockRoom -= buyValue;
        }
    }

    function _buy(uint256 id, address a, uint256 buyValue, uint256 basePrice, uint256 deadline)
        internal
        returns (bool)
    {
        uint256 p = _assetPrice(a, true);
        uint256 baseScale = 10 ** IERC20Metadata(asset()).decimals();
        uint256 expectedOut = Math.mulDiv(buyValue, basePrice * 10 ** assetDecimals[a], p * baseScale);
        uint256 minOut = (expectedOut * (BPS - maxSlippageBps)) / BPS;
        return _swap(id, asset(), a, buyValue, minOut, deadline);
    }

    function _swap(uint256 id, address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint256 deadline)
        internal
        returns (bool ok)
    {
        if (gasleft() < MIN_SWAP_GAS) revert InsufficientGas();
        IDexAdapter dex = modules.dex;
        IERC20(tokenIn).forceApprove(address(dex), amountIn);
        try dex.swapExactIn(tokenIn, tokenOut, amountIn, minOut, address(this), deadline) returns (uint256 out) {
            emit Trade(id, tokenIn, tokenOut, amountIn, out);
            ok = true;
        } catch (bytes memory reason) {
            emit TradeFailed(id, tokenIn, tokenOut, amountIn, reason);
        }
        IERC20(tokenIn).forceApprove(address(dex), 0);
    }

    function _stockValue(uint256[] memory values) internal view returns (uint256 v) {
        uint256 n = _holdings.length;
        for (uint256 i; i < n; ++i) {
            if (isStockAsset[_holdings[i]]) v += values[i];
        }
    }

    function _ensureHolding(address a, bool stock) internal {
        if (stock && !isStockAsset[a]) isStockAsset[a] = true; // once a stock, always counted as a stock
        if (isHolding[a]) return;
        if (a == address(0) || a == asset()) revert ZeroAddress();
        if (_holdings.length >= MAX_HOLDINGS) revert TooManyHoldings();
        isHolding[a] = true;
        assetDecimals[a] = IERC20Metadata(a).decimals();
        _holdings.push(a);
        emit HoldingAdded(a, stock);
    }

    function cancelRebalance() external {
        if (!hasRole(GUARDIAN_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, GUARDIAN_ROLE);
        }
        plan.active = false;
        emit RebalanceCancelled(rebalanceId);
    }

    // ============================= views =============================

    function holdings() external view returns (address[] memory) {
        return _holdings;
    }

    /// @notice Current allocation for UIs: holdings, their base-unit values, and weights in bps (lenient pricing).
    // slither-disable-next-line incorrect-equality
    function allocation()
        external
        view
        returns (address[] memory assets, uint256[] memory values, uint256[] memory weightsBps, uint256 idle, uint256 nav)
    {
        (nav, values,) = _valuation(false);
        assets = _holdings;
        idle = _idle();
        weightsBps = new uint256[](assets.length);
        if (nav == 0) return (assets, values, weightsBps, idle, nav);
        for (uint256 i; i < assets.length; ++i) {
            weightsBps[i] = (values[i] * BPS) / nav;
        }
    }

    // slither-disable-next-line incorrect-equality
    function stockWeightBps() external view returns (uint256) {
        (uint256 nav, uint256[] memory values,) = _valuation(false);
        return nav == 0 ? 0 : (_stockValue(values) * BPS) / nav;
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ============================= admin (Timelock) =============================

    function setMgmtFeeBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _checkBounds(bps, 0, MAX_MGMT_FEE_BPS);
        _accrueFee();
        mgmtFeeBps = bps;
        emit ConfigUpdated("mgmtFeeBps", bps);
    }

    function setBufferBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _checkBounds(bps, 0, 2000);
        bufferBps = bps;
        emit ConfigUpdated("bufferBps", bps);
    }

    function setMaxSlippageBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _checkBounds(bps, 10, 300);
        maxSlippageBps = bps;
        emit ConfigUpdated("maxSlippageBps", bps);
    }

    function setNavDeviationBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _checkBounds(bps, 200, 3000);
        navDeviationBps = bps;
        emit ConfigUpdated("navDeviationBps", bps);
    }

    function setChunking(uint8 count, uint32 interval) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _checkBounds(count, 1, 12);
        _checkBounds(interval, 5 minutes, 4 hours);
        chunkCount = count;
        chunkInterval = interval;
        emit ConfigUpdated("chunkCount", count);
        emit ConfigUpdated("chunkInterval", interval);
    }

    function setRebalanceInterval(uint32 interval) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _checkBounds(interval, MIN_REBALANCE_INTERVAL, 30 days);
        rebalanceInterval = interval;
        emit ConfigUpdated("rebalanceInterval", interval);
    }

    function setDepositCap(uint256 cap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        depositCap = cap;
        emit ConfigUpdated("depositCap", cap);
    }

    function setMinTradeValue(uint256 v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minTradeValue = v;
        emit ConfigUpdated("minTradeValue", v);
    }

    function setDexAdapter(IDexAdapter d) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(d) == address(0)) revert ZeroAddress();
        modules.dex = d;
        emit ModuleUpdated("dex", address(d));
    }

    function setOracleAdapter(IOracleAdapter o) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(o) == address(0)) revert ZeroAddress();
        modules.oracle = o;
        emit ModuleUpdated("oracle", address(o));
    }

    function setComplianceRegistry(IComplianceRegistry c) external onlyRole(DEFAULT_ADMIN_ROLE) {
        modules.compliance = c;
        emit ModuleUpdated("compliance", address(c));
    }

    function setFeeCollector(address fc) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (fc == address(0)) revert ZeroAddress();
        _accrueFee();
        modules.feeCollector = fc;
        emit ModuleUpdated("feeCollector", fc);
    }

    function _checkBounds(uint256 v, uint256 min, uint256 max) internal pure {
        if (v < min || v > max) revert OutOfBounds(v, min, max);
    }

    // ============================= overrides =============================

    function decimals() public view override(ERC4626Upgradeable) returns (uint8) {
        return super.decimals();
    }
}
