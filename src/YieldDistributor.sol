// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControlDefaultAdminRulesUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IYieldDistributor} from "./interfaces/IYieldDistributor.sol";

/**
 * @title YieldDistributor
 * @notice Gradually drips yield to sVUSD vault to prevent sandwich attacks
 * @dev Yield is distributed linearly over a configurable duration period.
 *      When new yield is added, remaining undistributed yield is combined
 *      with the new amount and the distribution period is extended.
 *      Uses AccessControlDefaultAdminRulesUpgradeable for secure admin transfers with delay.
 */
contract YieldDistributor is IYieldDistributor, AccessControlDefaultAdminRulesUpgradeable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");
    uint256 public constant DEFAULT_YIELD_DURATION = 7 days;
    uint256 public constant MIN_YIELD_DURATION = 1 days;
    uint48 public constant DEFAULT_ADMIN_DELAY = 3 days;
    uint256 internal constant PRECISION = 1e18;

    /*//////////////////////////////////////////////////////////////
                           ERC-7201 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:yielddistributor.storage.main
    struct YieldDistributorStorage {
        IERC20 asset;
        address vault;
        uint256 yieldDuration;
        uint256 periodFinish;
        uint256 rewardRate;
        uint256 lastUpdateTime;
    }

    // keccak256(abi.encode(uint256(keccak256("yielddistributor.storage.main")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YIELD_DISTRIBUTOR_STORAGE_LOCATION =
        0xa4bf24aa89006e158355fd46322f9e11d692b1c14ce675eaa1e0885d19961500;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error CannotRescueAsset();
    error InvalidDuration(uint256 duration, uint256 minDuration);
    error OnlyVault();
    error ZeroAddress();
    error ZeroAmount();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event YieldDistributed(address indexed distributor, uint256 amount, uint256 newRewardRate, uint256 periodFinish);
    event YieldDurationUpdated(uint256 previousDuration, uint256 newDuration);
    event YieldPulled(uint256 amount);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize the YieldDistributor
    /// @dev Uses DEFAULT_ADMIN_DELAY (3 days) for admin transfer delay
    /// @param asset_ The asset token to distribute (VUSD)
    /// @param vault_ The vault that will receive yield
    /// @param admin_ The initial default admin of the contract
    function initialize(address asset_, address vault_, address admin_) external initializer {
        if (asset_ == address(0)) revert ZeroAddress();
        if (vault_ == address(0)) revert ZeroAddress();
        if (admin_ == address(0)) revert ZeroAddress();

        __AccessControlDefaultAdminRules_init(DEFAULT_ADMIN_DELAY, admin_);

        YieldDistributorStorage storage $ = _getYieldDistributorStorage();
        $.asset = IERC20(asset_);
        $.vault = vault_;
        $.yieldDuration = DEFAULT_YIELD_DURATION;
    }

    /*//////////////////////////////////////////////////////////////
                   USER-FACING WRITE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pull accrued yield to the vault
    /// @dev Only callable by the vault contract. Transfers all pending yield
    ///      that has accrued since the last pull based on the linear drip rate.
    ///      Updates lastUpdateTime to current timestamp.
    /// @return amount_ The amount of yield transferred to the vault
    function pullYield() external returns (uint256 amount_) {
        YieldDistributorStorage storage $ = _getYieldDistributorStorage();
        if (msg.sender != $.vault) revert OnlyVault();

        amount_ = _pendingYield($);

        if (amount_ > 0) {
            $.lastUpdateTime = block.timestamp;
            $.asset.safeTransfer(msg.sender, amount_);
            emit YieldPulled(amount_);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    USER-FACING VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the asset token being distributed
    /// @return The asset token (IERC20)
    function asset() external view returns (IERC20) {
        return _getYieldDistributorStorage().asset;
    }

    /// @notice Get the timestamp of the last yield pull
    /// @return The Unix timestamp when yield was last pulled
    function lastUpdateTime() external view returns (uint256) {
        return _getYieldDistributorStorage().lastUpdateTime;
    }

    /// @notice Calculate pending yield available to pull
    /// @dev Calculates based on time elapsed since last pull multiplied by reward rate.
    ///      Returns 0 if no distribution is active or period has not started.
    /// @return The amount of yield tokens available to pull
    function pendingYield() public view returns (uint256) {
        return _pendingYield(_getYieldDistributorStorage());
    }

    /// @notice Get the timestamp when current distribution period ends
    /// @return The Unix timestamp when yield distribution ends
    function periodFinish() external view returns (uint256) {
        return _getYieldDistributorStorage().periodFinish;
    }

    /// @notice Get the current reward rate (tokens per second, scaled by 1e18)
    /// @return The reward rate used for linear yield distribution
    function rewardRate() external view returns (uint256) {
        return _getYieldDistributorStorage().rewardRate;
    }

    /// @notice Get the vault address that receives yield
    /// @return The vault address
    function vault() external view returns (address) {
        return _getYieldDistributorStorage().vault;
    }

    /// @notice Get the yield distribution duration
    /// @dev This is the period over which new yield is linearly distributed
    /// @return The duration in seconds for yield distribution
    function yieldDuration() external view returns (uint256) {
        return _getYieldDistributorStorage().yieldDuration;
    }

    /*//////////////////////////////////////////////////////////////
                     INTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculate pending yield from storage
    /// @param $ The storage pointer
    /// @return The amount of yield tokens available to pull
    function _pendingYield(YieldDistributorStorage storage $) internal view returns (uint256) {
        if ($.lastUpdateTime == 0 || $.rewardRate == 0) return 0;

        uint256 _endTime = block.timestamp < $.periodFinish ? block.timestamp : $.periodFinish;
        if (_endTime <= $.lastUpdateTime) return 0;

        return ((_endTime - $.lastUpdateTime) * $.rewardRate) / PRECISION;
    }

    /*//////////////////////////////////////////////////////////////
                      PRIVATE VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the storage pointer for ERC-7201 namespaced storage
    /// @return $ The storage pointer
    function _getYieldDistributorStorage() private pure returns (YieldDistributorStorage storage $) {
        assembly {
            $.slot := YIELD_DISTRIBUTOR_STORAGE_LOCATION
        }
    }

    /*//////////////////////////////////////////////////////////////
                       CONTROLLED FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Distribute yield to be dripped to the vault
    /// @dev Combines remaining undistributed yield with new amount and extends period.
    ///      Only callable by addresses with DISTRIBUTOR_ROLE.
    /// @param amount_ The amount of yield to distribute
    function distribute(uint256 amount_) external onlyRole(DISTRIBUTOR_ROLE) {
        if (amount_ == 0) revert ZeroAmount();

        YieldDistributorStorage storage $ = _getYieldDistributorStorage();

        $.asset.safeTransferFrom(msg.sender, address(this), amount_);

        uint256 _remaining;
        if (block.timestamp < $.periodFinish) {
            _remaining = (($.periodFinish - $.lastUpdateTime) * $.rewardRate) / PRECISION;
        }

        uint256 _newTotal = _remaining + amount_;
        $.rewardRate = (_newTotal * PRECISION) / $.yieldDuration;
        $.lastUpdateTime = block.timestamp;
        $.periodFinish = block.timestamp + $.yieldDuration;

        emit YieldDistributed(msg.sender, amount_, $.rewardRate, $.periodFinish);
    }

    /// @notice Rescue tokens accidentally sent to this contract
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. Cannot rescue the distribution asset.
    /// @param token_ The token to rescue
    /// @param to_ The address to send rescued tokens to
    /// @param amount_ The amount to rescue
    function rescueTokens(address token_, address to_, uint256 amount_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token_ == address(_getYieldDistributorStorage().asset)) revert CannotRescueAsset();
        if (to_ == address(0)) revert ZeroAddress();

        IERC20(token_).safeTransfer(to_, amount_);
    }

    /// @notice Update the yield distribution duration
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. Only affects future distributions,
    ///      not current ongoing distribution. Must be >= MIN_YIELD_DURATION (1 day).
    /// @param duration_ The new yield duration
    function updateYieldDuration(uint256 duration_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (duration_ < MIN_YIELD_DURATION) {
            revert InvalidDuration(duration_, MIN_YIELD_DURATION);
        }

        YieldDistributorStorage storage $ = _getYieldDistributorStorage();
        emit YieldDurationUpdated($.yieldDuration, duration_);
        $.yieldDuration = duration_;
    }
}
