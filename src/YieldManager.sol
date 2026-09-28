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
/// @notice Harvests treasury excess into a pegged token buffer and pays stakers from it at a target APR,
/// capped per distribution period.
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

    uint256 public constant MAX_BPS = 10_000;
    /// @notice Guards against a mistyped `targetApyBps`
    uint256 public constant MAX_TARGET_APY_BPS = 5_000;
    /// @dev YieldDistributor's `rewardRate` scale
    uint256 private constant RATE_PRECISION = 1e18;
    uint256 private constant YEAR = 365 days;

    /// @notice Pegged token
    IPeggedToken public immutable PEGGED_TOKEN;

    /// @notice Yield distributor
    IYieldDistributor public immutable YIELD_DISTRIBUTOR;

    /// @notice Max pegged tokens dripped per distributor `yieldDuration`; a shorter duration raises its weekly rate
    uint256 public absoluteCap;

    /// @notice Target staker APR in BPS (simple) on the staking vault's `totalAssets`
    uint256 public targetApyBps;

    /*/////////////////////////////////////////////////////////////
                            EVENTS
    /////////////////////////////////////////////////////////////*/

    event AbsoluteCapUpdated(uint256 previousCap, uint256 newCap);
    event Distributed(address indexed caller, uint256 amount, uint256 bufferLeft);
    event Harvested(address indexed token, uint256 tokenAmount, uint256 peggedTokenAmount);
    event Swept(address indexed token, uint256 amount, address indexed receiver);
    event TargetApyUpdated(uint256 previousApyBps, uint256 newApyBps);

    /*/////////////////////////////////////////////////////////////
                            ERRORS
    /////////////////////////////////////////////////////////////*/

    error AbsoluteCapIsZero();
    error AccessControlUnauthorizedAccount(address account, bytes32 role);
    error AddressIsZero();
    error AssetMismatch();
    error DripExceedsTarget(uint256 drip, uint256 target);
    error TargetApyTooHigh(uint256 apyBps, uint256 maxApyBps);

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
    /// @param targetApyBps_ Initial target APR in BPS
    /// @param absoluteCap_ Initial max pegged tokens per distribution period
    constructor(
        IPeggedToken peggedToken_,
        IYieldDistributor yieldDistributor_,
        uint256 targetApyBps_,
        uint256 absoluteCap_
    ) {
        if (address(peggedToken_) == address(0) || address(yieldDistributor_) == address(0)) {
            revert AddressIsZero();
        }
        if (address(yieldDistributor_.asset()) != address(peggedToken_)) revert AssetMismatch();

        PEGGED_TOKEN = peggedToken_;
        YIELD_DISTRIBUTOR = yieldDistributor_;
        _updateTargetApy(targetApyBps_);
        _updateAbsoluteCap(absoluteCap_);
    }

    /*/////////////////////////////////////////////////////////////
                    EXTERNAL FUNCTIONS
    /////////////////////////////////////////////////////////////*/

    /**
     * @notice KEEPER_ROLE: Top up the YieldDistributor from the buffer so it drips at the target rate.
     * @dev Keeper-gated: the target reads spot `totalAssets`, which a flash deposit can inflate.
     * @return _distributed Pegged tokens sent to the YieldDistributor
     */
    function distribute() external nonReentrant onlyRole(KEEPER_ROLE) returns (uint256 _distributed) {
        return _distribute();
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
     * @return _minted Pegged tokens added to the buffer
     * @return _distributed Pegged tokens sent to the YieldDistributor
     */
    function harvestAndDistribute(address token_, uint256 minPeggedTokenOut_)
        external
        nonReentrant
        onlyRole(KEEPER_ROLE)
        returns (uint256 _minted, uint256 _distributed)
    {
        _minted = _harvest(token_, minPeggedTokenOut_);
        _distributed = _distribute();
    }

    /**
     * @notice DEFAULT_ADMIN_ROLE: Update the max pegged tokens dripped per distribution period.
     * @param absoluteCap_ New cap, nonzero
     */
    function setAbsoluteCap(uint256 absoluteCap_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _updateAbsoluteCap(absoluteCap_);
    }

    /**
     * @notice DEFAULT_ADMIN_ROLE: Update the target staker APR.
     * @dev Lowering it does not claw back what is already dripping; top-ups resume once the drip falls under it.
     * @param targetApyBps_ New target APR in BPS, at most `MAX_TARGET_APY_BPS`; 0 pauses distribution
     */
    function setTargetApy(uint256 targetApyBps_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _updateTargetApy(targetApyBps_);
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

    /// @notice Pegged tokens held for future distributions
    function buffer() public view returns (uint256) {
        return PEGGED_TOKEN.balanceOf(address(this));
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

    /**
     * @notice Pegged tokens the next `distribute` would send
     */
    function previewDistribute() public view returns (uint256) {
        return _previewDistribute(targetPerPeriod());
    }

    /**
     * @notice Pegged tokens the YieldDistributor should drip over one period
     * @dev 0 without shares, else a top-up would pile up for the next depositor. Spot `totalAssets` makes the
     * realized APR drift between top-ups: deposits dilute it until the next call, exits raise it until the drip
     * runs out (never clawed back), bounded by `absoluteCap`.
     */
    function targetPerPeriod() public view returns (uint256) {
        IYieldDistributor _distributor = YIELD_DISTRIBUTOR;
        IERC4626 _vault = IERC4626(_distributor.vault());
        if (_vault.totalSupply() == 0) return 0;
        uint256 _totalAssets = _vault.totalAssets();
        uint256 _target = Math.mulDiv(_totalAssets, targetApyBps * _distributor.yieldDuration(), MAX_BPS * YEAR);
        return Math.min(_target, absoluteCap);
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

    /// @dev Reverts if the distributor rolls over more than `undistributed()` predicts, e.g. one that does not
    /// pull accrued yield before rescheduling.
    function _distribute() private returns (uint256 _distributed) {
        IYieldDistributor _distributor = YIELD_DISTRIBUTOR;
        uint256 _target = targetPerPeriod();
        _distributed = _previewDistribute(_target);
        if (_distributed == 0) return 0;

        PEGGED_TOKEN.forceApprove(address(_distributor), _distributed);
        _distributor.distribute(_distributed);

        uint256 _drip = ((_distributor.periodFinish() - block.timestamp) * _distributor.rewardRate()) / RATE_PRECISION;
        if (_drip > _target) revert DripExceedsTarget(_drip, _target);

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

    function _updateTargetApy(uint256 targetApyBps_) private {
        if (targetApyBps_ > MAX_TARGET_APY_BPS) revert TargetApyTooHigh(targetApyBps_, MAX_TARGET_APY_BPS);
        emit TargetApyUpdated(targetApyBps, targetApyBps_);
        targetApyBps = targetApyBps_;
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
