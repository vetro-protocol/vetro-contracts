// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPeggedToken} from "./interfaces/IPeggedToken.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {IGateway} from "./interfaces/IGateway.sol";
import {IYieldDistributor} from "./interfaces/IYieldDistributor.sol";

/// @title YieldManager: Buffered, rate-targeted staker yield
/// @notice Harvests treasury excess into a pegged token buffer; the keeper pays stakers from it, capped by an
/// admin-set APR and a weekly token amount.
/// @dev Harvesting re-deposits through the Gateway, so the collateral stays in the treasury earning while
/// the buffer waits. Needs UMM_ROLE (Treasury) and DISTRIBUTOR_ROLE (YieldDistributor).
contract YieldManager is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeERC20 for IPeggedToken;

    /*/////////////////////////////////////////////////////////////
                        STATE VARIABLES
    /////////////////////////////////////////////////////////////*/

    string public constant VERSION = "2.0.0";

    // Inlined role IDs matching Treasury's definitions to avoid chained external calls
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    /// @notice Guards against a mistyped `maxAprBps`
    uint256 public constant MAX_APR_BPS = 5_000;
    uint256 public constant MAX_BPS = 10_000;
    /// @dev Window `absoluteCap` is expressed in, independent of the distributor's `yieldDuration`
    uint256 private constant CAP_WINDOW = 7 days;
    /// @dev YieldDistributor's `rewardRate` scale
    uint256 private constant RATE_PRECISION = 1e18;
    uint256 private constant YEAR = 365 days;

    /// @notice Pegged token
    IPeggedToken public immutable PEGGED_TOKEN;

    /// @notice Yield distributor
    IYieldDistributor public immutable YIELD_DISTRIBUTOR;

    /// @notice Max pegged tokens dripped per 7 days, whatever `totalAssets` or `yieldDuration` do
    uint256 public absoluteCap;

    /// @notice Max staker APR in BPS (simple) on the staking vault's `totalAssets` the drip may run at
    uint256 public maxAprBps;

    /*/////////////////////////////////////////////////////////////
                            EVENTS
    /////////////////////////////////////////////////////////////*/

    event AbsoluteCapUpdated(uint256 previousCap, uint256 newCap);
    event Distributed(address indexed caller, uint256 amount, uint256 bufferLeft);
    event Harvested(address indexed token, uint256 tokenAmount, uint256 peggedTokenAmount);
    event MaxAprUpdated(uint256 previousAprBps, uint256 newAprBps);
    event Swept(address indexed token, uint256 amount, address indexed receiver);

    /*/////////////////////////////////////////////////////////////
                            ERRORS
    /////////////////////////////////////////////////////////////*/

    error AbsoluteCapIsZero();
    error AccessControlUnauthorizedAccount(address account, bytes32 role);
    error AddressIsZero();
    error AmountIsZero();
    error AssetMismatch();
    error DripExceedsCap(uint256 drip, uint256 cap);
    error MaxAprTooHigh(uint256 aprBps, uint256 maxAprBps);

    /*/////////////////////////////////////////////////////////////
                            MODIFIERS
    /////////////////////////////////////////////////////////////*/

    modifier onlyRole(bytes32 role_) {
        _requireRole(role_);
        _;
    }

    /*/////////////////////////////////////////////////////////////
                            FUNCTIONS
    /////////////////////////////////////////////////////////////*/

    /// @param peggedToken_ Pegged token
    /// @param yieldDistributor_ Yield distributor (its asset must be `peggedToken_`)
    /// @param maxAprBps_ Initial max APR in BPS
    /// @param absoluteCap_ Initial max pegged tokens dripped per 7 days
    constructor(
        IPeggedToken peggedToken_,
        IYieldDistributor yieldDistributor_,
        uint256 maxAprBps_,
        uint256 absoluteCap_
    ) {
        if (address(peggedToken_) == address(0) || address(yieldDistributor_) == address(0)) {
            revert AddressIsZero();
        }
        if (address(yieldDistributor_.asset()) != address(peggedToken_)) revert AssetMismatch();

        PEGGED_TOKEN = peggedToken_;
        YIELD_DISTRIBUTOR = yieldDistributor_;
        _updateMaxApr(maxAprBps_);
        _updateAbsoluteCap(absoluteCap_);
    }

    /*/////////////////////////////////////////////////////////////
                    EXTERNAL FUNCTIONS
    /////////////////////////////////////////////////////////////*/

    /**
     * @notice KEEPER_ROLE: Send up to `amount_` from the buffer to the YieldDistributor, clamped to `maxDistribute`.
     * @dev A fixed amount can't be inflated by a deposit front-running this call; see `amountForApr`. Clamping keeps
     * a stale amount from reverting when `totalAssets` drops before inclusion. Each call re-spreads the remaining
     * drip over a fresh `yieldDuration`, so an amount short of the target lowers the current rate, and a keeper can
     * delay payouts but not raise them past the caps.
     * @param amount_ Max pegged tokens to send, nonzero
     * @return _distributed Pegged tokens sent to the YieldDistributor
     */
    function distribute(uint256 amount_) external nonReentrant onlyRole(KEEPER_ROLE) returns (uint256 _distributed) {
        return _distribute(amount_);
    }

    /**
     * @notice KEEPER_ROLE: Harvest treasury excess payable in `token_` into the buffer.
     * @dev Compute `minPeggedTokenOut_` off-chain (e.g. eth_call-simulate this function); deriving it
     * on-chain from `previewDeposit` is circular and never reverts.
     * @param token_ Whitelisted collateral token to harvest the excess in
     * @param minPeggedTokenOut_ Minimum pegged tokens the Gateway mint must produce
     * @return _minted Pegged tokens added to the buffer
     */
    function harvest(address token_, uint256 minPeggedTokenOut_)
        external
        nonReentrant
        onlyRole(KEEPER_ROLE)
        returns (uint256 _minted)
    {
        return _harvest(token_, minPeggedTokenOut_);
    }

    /**
     * @notice KEEPER_ROLE: `harvest` then `distribute` in one call.
     * @param token_ Whitelisted collateral token to harvest the excess in
     * @param minPeggedTokenOut_ Minimum pegged tokens the Gateway mint must produce
     * @param amount_ Max pegged tokens to send to the YieldDistributor, nonzero
     * @return _minted Pegged tokens added to the buffer
     * @return _distributed Pegged tokens sent to the YieldDistributor
     */
    function harvestAndDistribute(address token_, uint256 minPeggedTokenOut_, uint256 amount_)
        external
        nonReentrant
        onlyRole(KEEPER_ROLE)
        returns (uint256 _minted, uint256 _distributed)
    {
        _minted = _harvest(token_, minPeggedTokenOut_);
        _distributed = _distribute(amount_);
    }

    /**
     * @notice DEFAULT_ADMIN_ROLE: Update the max pegged tokens dripped per 7 days.
     * @param absoluteCap_ New cap, nonzero
     */
    function setAbsoluteCap(uint256 absoluteCap_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _updateAbsoluteCap(absoluteCap_);
    }

    /**
     * @notice DEFAULT_ADMIN_ROLE: Update the max staker APR.
     * @dev Lowering it does not claw back what is already dripping.
     * @param maxAprBps_ New max APR in BPS, at most `MAX_APR_BPS`; 0 pauses distribution
     */
    function setMaxApr(uint256 maxAprBps_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _updateMaxApr(maxAprBps_);
    }

    /**
     * @notice DEFAULT_ADMIN_ROLE: Sweep tokens from this contract, including the buffer.
     * @param token_ Token to sweep
     * @param receiver_ Address to receive the swept tokens
     */
    function sweep(address token_, address receiver_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (receiver_ == address(0)) revert AddressIsZero();
        uint256 _amount = IERC20(token_).balanceOf(address(this));
        IERC20(token_).safeTransfer(receiver_, _amount);
        emit Swept(token_, _amount, receiver_);
    }

    /*/////////////////////////////////////////////////////////////
                    EXTERNAL VIEW FUNCTIONS
    /////////////////////////////////////////////////////////////*/

    /// @notice Returns the name of the YieldManager
    function NAME() external view returns (string memory) {
        return string.concat(IERC20Metadata(address(PEGGED_TOKEN)).symbol(), "-YieldManager");
    }

    /*/////////////////////////////////////////////////////////////
                        PUBLIC VIEW FUNCTIONS
    /////////////////////////////////////////////////////////////*/

    /**
     * @notice Pegged tokens to `distribute` now so the drip runs at `aprBps_`, limited by the buffer
     * @dev Not capped: above `maxDistribute`, `distribute` clamps instead.
     */
    function amountForApr(uint256 aprBps_) public view returns (uint256) {
        return _previewDistribute(_dripPerPeriod(aprBps_));
    }

    /// @notice Pegged tokens held for future distributions
    function buffer() public view returns (uint256) {
        return PEGGED_TOKEN.balanceOf(address(this));
    }

    /**
     * @notice APR in BPS the YieldDistributor drips at now, on the staking vault's `totalAssets`
     * @dev Unbounded at dust share supply, where a small `totalAssets` still receives the whole drip.
     */
    function currentAprBps() public view returns (uint256) {
        IYieldDistributor _distributor = YIELD_DISTRIBUTOR;
        if (block.timestamp >= _distributor.periodFinish()) return 0;
        IERC4626 _vault = IERC4626(_distributor.vault());
        if (_vault.totalSupply() == 0) return 0;
        uint256 _totalAssets = _vault.totalAssets();
        if (_totalAssets == 0) return 0;
        return Math.mulDiv(_distributor.rewardRate(), YEAR * MAX_BPS, RATE_PRECISION * _totalAssets);
    }

    /// @notice Returns the gateway
    function gateway() public view returns (IGateway) {
        return IGateway(PEGGED_TOKEN.gateway());
    }

    /**
     * @notice The yield available to harvest, i.e. the excess of the treasury reserve over
     *  the pegged token's backed supply: `reserve - (totalSupply - amoSupply)`.
     * @dev Reverts if any whitelisted token's oracle is stale or out of tolerance.
     * @return _excessPegged Harvestable excess in pegged token units, or 0 if none.
     */
    function harvestable() public view returns (uint256 _excessPegged) {
        uint256 _backedSupply = PEGGED_TOKEN.totalSupply() - gateway().amoSupply();
        uint256 _reserve = treasury().reserve();
        return _reserve > _backedSupply ? _reserve - _backedSupply : 0;
    }

    /// @notice Most `distribute` sends now: the headroom under both caps, limited by the buffer
    function maxDistribute() public view returns (uint256) {
        return _previewDistribute(_maxDripPerPeriod());
    }

    /// @notice Returns the treasury
    function treasury() public view returns (ITreasury) {
        return ITreasury(PEGGED_TOKEN.treasury());
    }

    /**
     * @notice Yield `YieldDistributor.distribute` will roll into its next period
     * @dev Mirrors its pull-then-rollover; rounds up so a repeat call tops up at most 1 wei.
     */
    function undistributed() public view returns (uint256) {
        IYieldDistributor _distributor = YIELD_DISTRIBUTOR;
        uint256 _rewardRate = _distributor.rewardRate();
        uint256 _lastUpdateTime = _distributor.lastUpdateTime();
        if (_rewardRate == 0 || _lastUpdateTime == 0) return 0;
        if (_distributor.pendingYield() > 0) _lastUpdateTime = block.timestamp;

        uint256 _periodFinish = _distributor.periodFinish();
        if (_lastUpdateTime >= _periodFinish) return 0;
        return Math.mulDiv(_periodFinish - _lastUpdateTime, _rewardRate, RATE_PRECISION, Math.Rounding.Ceil);
    }

    /*/////////////////////////////////////////////////////////////
                        PRIVATE FUNCTIONS
    /////////////////////////////////////////////////////////////*/

    /// @dev A clamped zero is a no-op, not a revert, so `harvestAndDistribute` keeps its harvest when the caps are
    /// full. The drip check reverts on a distributor that does not pull accrued yield before rescheduling, as it rolls
    /// over more than `undistributed()` predicts.
    function _distribute(uint256 amount_) private returns (uint256 _distributed) {
        if (amount_ == 0) revert AmountIsZero();

        uint256 _cap = _maxDripPerPeriod();
        _distributed = Math.min(amount_, _previewDistribute(_cap));
        if (_distributed == 0) return 0;

        IYieldDistributor _distributor = YIELD_DISTRIBUTOR;
        PEGGED_TOKEN.forceApprove(address(_distributor), _distributed);
        _distributor.distribute(_distributed);

        uint256 _drip = ((_distributor.periodFinish() - block.timestamp) * _distributor.rewardRate()) / RATE_PRECISION;
        if (_drip > _cap) revert DripExceedsCap(_drip, _cap);

        emit Distributed(msg.sender, _distributed, buffer());
    }

    function _harvest(address token_, uint256 minPeggedTokenOut_) private returns (uint256 _minted) {
        uint256 _harvested = treasury().harvest(token_, address(this));
        if (_harvested == 0) return 0;

        IGateway _gateway = gateway();
        IERC20(token_).forceApprove(address(_gateway), _harvested);
        _minted = _gateway.deposit(token_, _harvested, minPeggedTokenOut_, address(this));

        emit Harvested(token_, _harvested, _minted);
    }

    function _updateAbsoluteCap(uint256 absoluteCap_) private {
        if (absoluteCap_ == 0) revert AbsoluteCapIsZero();
        emit AbsoluteCapUpdated(absoluteCap, absoluteCap_);
        absoluteCap = absoluteCap_;
    }

    function _updateMaxApr(uint256 maxAprBps_) private {
        if (maxAprBps_ > MAX_APR_BPS) revert MaxAprTooHigh(maxAprBps_, MAX_APR_BPS);
        emit MaxAprUpdated(maxAprBps, maxAprBps_);
        maxAprBps = maxAprBps_;
    }

    /// @dev Pegged tokens dripped over one period at `aprBps_`; 0 without shares, else a distribution would pile
    /// up for the next depositor. Spot `totalAssets` makes the realized APR drift between top-ups: deposits dilute
    /// it, exits raise it until the drip runs out (never clawed back).
    function _dripPerPeriod(uint256 aprBps_) private view returns (uint256) {
        IYieldDistributor _distributor = YIELD_DISTRIBUTOR;
        IERC4626 _vault = IERC4626(_distributor.vault());
        if (_vault.totalSupply() == 0) return 0;
        return Math.mulDiv(_vault.totalAssets(), aprBps_ * _distributor.yieldDuration(), MAX_BPS * YEAR);
    }

    /// @dev `absoluteCap` bounds what a keeper-timed deposit can add to spot `totalAssets` before a distribution.
    /// It caps the drip outstanding, so a buffer can pre-fund up to one more period on top of what it pays.
    function _maxDripPerPeriod() private view returns (uint256) {
        uint256 _cap = Math.mulDiv(absoluteCap, YIELD_DISTRIBUTOR.yieldDuration(), CAP_WINDOW);
        return Math.min(_dripPerPeriod(maxAprBps), _cap);
    }

    function _previewDistribute(uint256 target_) private view returns (uint256) {
        uint256 _undistributed = undistributed();
        if (target_ <= _undistributed) return 0;
        return Math.min(target_ - _undistributed, buffer());
    }

    /// @dev Reverts unless `msg.sender` holds `role_` on the Treasury
    function _requireRole(bytes32 role_) private view {
        if (!treasury().hasRole(role_, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, role_);
        }
    }
}
