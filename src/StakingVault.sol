// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IYieldDistributor} from "./interfaces/IYieldDistributor.sol";
import {IVaultRewards} from "./interfaces/IVaultRewards.sol";
import {IStakingVault} from "./interfaces/IStakingVault.sol";

/**
 * @title StakingVault
 * @notice ERC4626 yield-bearing vault with cooldown withdrawal mechanism
 * @dev Implements a cooldown period for withdrawals to prevent sandwich attacks.
 *      Whitelisted addresses can withdraw instantly when cooldown is enabled.
 *      Shares in cooldown do not earn yield - they are burned and assets are locked.
 */
contract StakingVault is IStakingVault, ERC4626Upgradeable, Ownable2StepUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant DEFAULT_COOLDOWN_DURATION = 7 days;
    uint256 public constant MIN_COOLDOWN_DURATION = 1 days;
    uint256 public constant MAX_COOLDOWN_DURATION = 30 days;

    /*//////////////////////////////////////////////////////////////
                           ERC-7201 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:vetro.storage.stakingVault
    struct StakingVaultStorage {
        address yieldDistributor;
        address vaultRewards;
        uint256 cooldownDuration;
        bool cooldownEnabled;
        uint256 totalAssetsInCooldown;
        uint256 nextRequestId;
        mapping(address account => bool whitelisted) instantWithdrawWhitelist;
        mapping(uint256 requestId => CooldownRequest request) cooldownRequests;
        mapping(address account => EnumerableSet.UintSet activeIds) activeRequestIds;
    }

    bytes32 private constant STAKING_VAULT_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("vetro.storage.stakingVault")) - 1)) & ~bytes32(uint256(0xff));

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error CooldownEnabled();
    error CooldownNotEnabled();
    error CooldownNotMatured(uint256 requestId, uint256 claimableAt);
    error InvalidCooldownDuration(uint256 duration, uint256 minDuration, uint256 maxDuration);
    error InvalidRequestId(uint256 requestId);
    error NotRequestOwner();
    error ZeroAddress();
    error ZeroAmount();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event CooldownDurationUpdated(uint256 previousDuration, uint256 newDuration);
    event CooldownEnabledUpdated(bool previousStatus, bool newStatus);
    event InstantWithdrawWhitelistUpdated(address indexed account, bool status);
    event VaultRewardsUpdated(address indexed previousVaultRewards, address indexed newVaultRewards);
    event WithdrawCancelled(address indexed owner, uint256 indexed requestId, uint256 assets, uint256 shares);
    event WithdrawClaimed(address indexed owner, address indexed receiver, uint256 indexed requestId, uint256 assets);
    event WithdrawRequested(
        address indexed owner, uint256 indexed requestId, uint256 shares, uint256 assets, uint256 claimableAt
    );
    event YieldDistributorUpdated(address indexed previousDistributor, address indexed newDistributor);

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

    /// @notice Initialize the staking vault
    /// @param asset_ The underlying asset
    /// @param name_ The name of the vault token
    /// @param symbol_ The symbol of the vault token
    /// @param owner_ The owner of the vault
    function initialize(address asset_, string memory name_, string memory symbol_, address owner_)
        external
        initializer
    {
        if (asset_ == address(0)) revert ZeroAddress();
        if (owner_ == address(0)) revert ZeroAddress();

        __ERC4626_init(IERC20(asset_));
        __ERC20_init(name_, symbol_);
        __Ownable_init(owner_);

        StakingVaultStorage storage $ = _getStakingVaultStorage();
        $.cooldownDuration = DEFAULT_COOLDOWN_DURATION;
        $.cooldownEnabled = true;
    }

    /*//////////////////////////////////////////////////////////////
                   EXTERNAL STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingVault
    function cancelWithdraw(uint256 requestId_) external nonReentrant returns (uint256 shares_) {
        _pullYield();

        StakingVaultStorage storage $ = _getStakingVaultStorage();

        CooldownRequest storage _request = $.cooldownRequests[requestId_];
        uint256 _assets = _request.assets;

        if (_assets == 0) revert InvalidRequestId(requestId_);

        address _owner = _request.owner;

        // Only the request owner can cancel
        if (msg.sender != _owner) revert NotRequestOwner();

        // Remove from active set
        $.activeRequestIds[_owner].remove(requestId_);

        // Calculate shares at current rate BEFORE updating totalAssetsInCooldown
        // This ensures the share calculation uses correct totalAssets() value
        shares_ = previewDeposit(_assets);

        // Update total assets in cooldown AFTER calculating shares
        $.totalAssetsInCooldown -= _assets;
        delete $.cooldownRequests[requestId_];

        _mint(_owner, shares_);

        emit WithdrawCancelled(_owner, requestId_, _assets, shares_);
    }

    /// @inheritdoc IStakingVault
    function claimWithdraw(uint256 requestId_, address receiver_) external nonReentrant returns (uint256 assets) {
        assets = _claimWithdraw(requestId_, receiver_);
    }

    /// @inheritdoc IStakingVault
    function claimWithdrawBatch(uint256[] calldata requestIds_, address receiver_)
        external
        nonReentrant
        returns (uint256 totalAssets_)
    {
        uint256 _length = requestIds_.length;
        for (uint256 _i; _i < _length; ++_i) {
            totalAssets_ += _claimWithdraw(requestIds_[_i], receiver_);
        }
    }

    /// @inheritdoc IStakingVault
    function requestRedeem(uint256 shares_, address owner_)
        external
        nonReentrant
        returns (uint256 requestId, uint256 assets)
    {
        (requestId, assets) = _requestRedeem(shares_, owner_);
    }

    /// @inheritdoc IStakingVault
    function requestWithdraw(uint256 assets_, address owner_)
        external
        nonReentrant
        returns (uint256 requestId, uint256 shares)
    {
        (requestId, shares) = _requestWithdraw(assets_, owner_);
    }

    /// @notice Update the cooldown duration for withdrawals
    /// @dev Affects new requests only, not existing ones.
    ///      Must be between MIN_COOLDOWN_DURATION and MAX_COOLDOWN_DURATION.
    /// @param duration_ The new cooldown duration
    function updateCooldownDuration(uint256 duration_) external onlyOwner {
        if (duration_ < MIN_COOLDOWN_DURATION || duration_ > MAX_COOLDOWN_DURATION) {
            revert InvalidCooldownDuration(duration_, MIN_COOLDOWN_DURATION, MAX_COOLDOWN_DURATION);
        }

        StakingVaultStorage storage $ = _getStakingVaultStorage();
        emit CooldownDurationUpdated($.cooldownDuration, duration_);
        $.cooldownDuration = duration_;
    }

    /// @notice Enable or disable cooldown for non-whitelisted users
    /// @dev When disabled, all users can use instant withdraw/redeem
    /// @param enabled_ The new cooldown enabled status
    function updateCooldownEnabled(bool enabled_) external onlyOwner {
        StakingVaultStorage storage $ = _getStakingVaultStorage();
        emit CooldownEnabledUpdated($.cooldownEnabled, enabled_);
        $.cooldownEnabled = enabled_;
    }

    /// @notice Add or remove an address from the instant withdraw whitelist
    /// @dev Whitelisted addresses can bypass cooldown even when enabled
    /// @param account_ The account to update
    /// @param status_ The new whitelist status
    function updateInstantWithdrawWhitelist(address account_, bool status_) external onlyOwner {
        if (account_ == address(0)) revert ZeroAddress();

        StakingVaultStorage storage $ = _getStakingVaultStorage();
        $.instantWithdrawWhitelist[account_] = status_;

        emit InstantWithdrawWhitelistUpdated(account_, status_);
    }

    /// @notice Update the vault rewards contract address
    /// @dev Can be set to address(0) to disable rewards tracking
    /// @param vaultRewards_ The new vault rewards address
    function updateVaultRewards(address vaultRewards_) external onlyOwner {
        StakingVaultStorage storage $ = _getStakingVaultStorage();
        emit VaultRewardsUpdated($.vaultRewards, vaultRewards_);
        $.vaultRewards = vaultRewards_;
    }

    /// @notice Update the yield distributor address
    /// @dev Can be set to address(0) to disable yield distribution
    /// @param distributor_ The new yield distributor address
    function updateYieldDistributor(address distributor_) external onlyOwner {
        StakingVaultStorage storage $ = _getStakingVaultStorage();
        emit YieldDistributorUpdated($.yieldDistributor, distributor_);
        $.yieldDistributor = distributor_;
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingVault
    function cooldownDuration() external view returns (uint256) {
        return _getStakingVaultStorage().cooldownDuration;
    }

    /// @inheritdoc IStakingVault
    function cooldownEnabled() external view returns (bool) {
        return _getStakingVaultStorage().cooldownEnabled;
    }

    /// @inheritdoc IStakingVault
    function getActiveRequestIds(address account_) external view returns (uint256[] memory) {
        return _getStakingVaultStorage().activeRequestIds[account_].values();
    }

    /// @inheritdoc IStakingVault
    function getClaimableRequests(address account_)
        external
        view
        returns (uint256[] memory requestIds_, uint256[] memory assets_)
    {
        StakingVaultStorage storage $ = _getStakingVaultStorage();
        uint256[] memory _activeIds = $.activeRequestIds[account_].values();
        uint256 _length = _activeIds.length;

        // Allocate arrays with max possible size
        requestIds_ = new uint256[](_length);
        assets_ = new uint256[](_length);

        // Single pass: populate arrays
        uint256 _idx;
        for (uint256 _i; _i < _length; ++_i) {
            CooldownRequest storage _request = $.cooldownRequests[_activeIds[_i]];
            if (block.timestamp >= _request.claimableAt) {
                requestIds_[_idx] = _activeIds[_i];
                assets_[_idx] = _request.assets;
                _idx++;
            }
        }

        // Resize arrays to actual count using assembly
        assembly {
            mstore(requestIds_, _idx)
            mstore(assets_, _idx)
        }
    }

    /// @inheritdoc IStakingVault
    function getPendingRequests(address account_)
        external
        view
        returns (uint256[] memory requestIds_, uint256[] memory assets_, uint256[] memory claimableAt_)
    {
        StakingVaultStorage storage $ = _getStakingVaultStorage();
        uint256[] memory _activeIds = $.activeRequestIds[account_].values();
        uint256 _length = _activeIds.length;

        // Allocate arrays with max possible size
        requestIds_ = new uint256[](_length);
        assets_ = new uint256[](_length);
        claimableAt_ = new uint256[](_length);

        // Single pass: populate arrays
        uint256 _idx;
        for (uint256 _i; _i < _length; ++_i) {
            CooldownRequest storage _request = $.cooldownRequests[_activeIds[_i]];
            uint256 _claimableAt = _request.claimableAt;
            if (block.timestamp < _claimableAt) {
                requestIds_[_idx] = _activeIds[_i];
                assets_[_idx] = _request.assets;
                claimableAt_[_idx] = _claimableAt;
                _idx++;
            }
        }

        // Resize arrays to actual count using assembly
        assembly {
            mstore(requestIds_, _idx)
            mstore(assets_, _idx)
            mstore(claimableAt_, _idx)
        }
    }

    /// @inheritdoc IStakingVault
    function getRequestDetails(uint256 requestId_) external view returns (CooldownRequest memory) {
        return _getStakingVaultStorage().cooldownRequests[requestId_];
    }

    /// @inheritdoc IStakingVault
    function instantWithdrawWhitelist(address account_) external view returns (bool) {
        return _getStakingVaultStorage().instantWithdrawWhitelist[account_];
    }

    /// @inheritdoc IStakingVault
    function nextRequestId() external view returns (uint256) {
        return _getStakingVaultStorage().nextRequestId;
    }

    /// @inheritdoc IStakingVault
    function totalAssetsInCooldown() external view returns (uint256) {
        return _getStakingVaultStorage().totalAssetsInCooldown;
    }

    /// @inheritdoc IStakingVault
    function vaultRewards() external view returns (address) {
        return _getStakingVaultStorage().vaultRewards;
    }

    /// @inheritdoc IStakingVault
    function yieldDistributor() external view returns (address) {
        return _getStakingVaultStorage().yieldDistributor;
    }

    /*//////////////////////////////////////////////////////////////
                    PUBLIC STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit assets and receive vault shares
    /// @dev Pulls pending yield before deposit to ensure accurate share calculation.
    ///      Protected against reentrancy.
    /// @param assets_ The amount of assets to deposit
    /// @param receiver_ The address to receive the vault shares
    /// @return shares The amount of vault shares minted
    function deposit(uint256 assets_, address receiver_)
        public
        override(ERC4626Upgradeable, IERC4626)
        nonReentrant
        returns (uint256)
    {
        _pullYield();
        return super.deposit(assets_, receiver_);
    }

    /// @notice Mint exact amount of vault shares by depositing assets
    /// @dev Pulls pending yield before mint to ensure accurate asset calculation.
    ///      Protected against reentrancy.
    /// @param shares_ The exact amount of vault shares to mint
    /// @param receiver_ The address to receive the vault shares
    /// @return assets The amount of assets deposited
    function mint(uint256 shares_, address receiver_)
        public
        override(ERC4626Upgradeable, IERC4626)
        nonReentrant
        returns (uint256)
    {
        _pullYield();
        return super.mint(shares_, receiver_);
    }

    /// @notice Redeem vault shares for assets (instant withdrawal)
    /// @dev Only available when cooldown is disabled or owner is whitelisted.
    ///      Pulls pending yield before redeem. Protected against reentrancy.
    /// @param shares_ The amount of vault shares to redeem
    /// @param receiver_ The address to receive the assets
    /// @param owner_ The owner of the shares (requires allowance if not msg.sender)
    /// @return assets The amount of assets withdrawn
    function redeem(uint256 shares_, address receiver_, address owner_)
        public
        override(ERC4626Upgradeable, IERC4626)
        nonReentrant
        returns (uint256)
    {
        if (!_canInstantWithdraw(owner_)) revert CooldownEnabled();
        _pullYield();
        return super.redeem(shares_, receiver_, owner_);
    }

    /// @notice Withdraw exact amount of assets (instant withdrawal)
    /// @dev Only available when cooldown is disabled or owner is whitelisted.
    ///      Pulls pending yield before withdraw. Protected against reentrancy.
    /// @param assets_ The exact amount of assets to withdraw
    /// @param receiver_ The address to receive the assets
    /// @param owner_ The owner of the shares (requires allowance if not msg.sender)
    /// @return shares The amount of vault shares burned
    function withdraw(uint256 assets_, address receiver_, address owner_)
        public
        override(ERC4626Upgradeable, IERC4626)
        nonReentrant
        returns (uint256)
    {
        if (!_canInstantWithdraw(owner_)) revert CooldownEnabled();
        _pullYield();
        return super.withdraw(assets_, receiver_, owner_);
    }

    /*//////////////////////////////////////////////////////////////
                    PUBLIC VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get total assets available for yield (excludes assets in cooldown)
    /// @dev Assets in cooldown are locked and do not earn yield, so they are excluded
    ///      from the total used for share price calculation.
    /// @return Total assets earning yield in the vault
    function totalAssets() public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        StakingVaultStorage storage $ = _getStakingVaultStorage();
        uint256 _balance = IERC20(asset()).balanceOf(address(this));
        uint256 _inCooldown = $.totalAssetsInCooldown;
        // Prevent underflow if somehow _inCooldown > _balance
        return _balance > _inCooldown ? _balance - _inCooldown : 0;
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Process a withdrawal claim
    /// @dev Transfers locked assets to receiver and updates accounting
    /// @param requestId_ The request ID to claim
    /// @param receiver_ The address to receive the assets
    /// @return assets_ The amount of assets claimed
    function _claimWithdraw(uint256 requestId_, address receiver_) internal returns (uint256 assets_) {
        if (receiver_ == address(0)) revert ZeroAddress();
        _pullYield();

        StakingVaultStorage storage $ = _getStakingVaultStorage();

        CooldownRequest storage _request = $.cooldownRequests[requestId_];
        assets_ = _request.assets;
        if (assets_ == 0) revert InvalidRequestId(requestId_);
        if (block.timestamp < _request.claimableAt) {
            revert CooldownNotMatured(requestId_, _request.claimableAt);
        }

        address _owner = _request.owner;

        // Only the request owner can claim
        if (msg.sender != _owner) revert NotRequestOwner();

        // Remove from active set
        $.activeRequestIds[_owner].remove(requestId_);
        delete $.cooldownRequests[requestId_];
        // Update total assets in cooldown
        $.totalAssetsInCooldown -= assets_;

        // Transfer assets to receiver
        IERC20(asset()).safeTransfer(receiver_, assets_);

        emit WithdrawClaimed(_owner, receiver_, requestId_, assets_);
    }

    /// @notice Create a cooldown request
    /// @dev Burns shares and locks assets in cooldown
    /// @param assets_ The amount of assets to lock in cooldown
    /// @param shares_ The amount of shares to burn
    /// @param owner_ The owner of the shares
    /// @return requestId_ The ID of the created request
    function _createRequest(uint256 assets_, uint256 shares_, address owner_) internal returns (uint256 requestId_) {
        if (assets_ == 0 || shares_ == 0) revert ZeroAmount();
        StakingVaultStorage storage $ = _getStakingVaultStorage();
        if (!$.cooldownEnabled) revert CooldownNotEnabled();
        if (msg.sender != owner_) {
            _spendAllowance(owner_, msg.sender, shares_);
        }

        // Update total assets in cooldown
        $.totalAssetsInCooldown += assets_;
        // Burn shares (removes from yield earning)
        _burn(owner_, shares_);

        // Create cooldown request with global unique ID
        uint256 _claimableAt = $.cooldownDuration + block.timestamp;
        requestId_ = $.nextRequestId++;

        $.cooldownRequests[requestId_] = CooldownRequest({owner: owner_, assets: assets_, claimableAt: _claimableAt});

        $.activeRequestIds[owner_].add(requestId_);

        emit WithdrawRequested(owner_, requestId_, shares_, assets_, _claimableAt);
    }

    /// @notice Pull pending yield from the yield distributor
    /// @dev Called before deposit/mint/withdraw/redeem to update share price.
    ///      Skips pulling when totalSupply is 0 to prevent orphan yield that would
    ///      unfairly dilute users canceling withdrawals.
    function _pullYield() internal {
        StakingVaultStorage storage $ = _getStakingVaultStorage();
        if ($.yieldDistributor != address(0) && totalSupply() > 0) {
            IYieldDistributor($.yieldDistributor).pullYield();
        }
    }

    /// @notice Internal implementation of requestRedeem
    /// @param shares_ The amount of shares to redeem
    /// @param owner_ The owner of the shares
    /// @return requestId_ The ID of the created request
    /// @return assets_ The amount of assets that will be claimable
    function _requestRedeem(uint256 shares_, address owner_) internal returns (uint256 requestId_, uint256 assets_) {
        _pullYield();
        assets_ = previewRedeem(shares_);
        requestId_ = _createRequest(assets_, shares_, owner_);
    }

    /// @notice Internal implementation of requestWithdraw
    /// @param assets_ The amount of assets to withdraw
    /// @param owner_ The owner of the shares
    /// @return requestId_ The ID of the created request
    /// @return shares_ The amount of shares that were burned
    function _requestWithdraw(uint256 assets_, address owner_) internal returns (uint256 requestId_, uint256 shares_) {
        _pullYield();
        shares_ = previewWithdraw(assets_);
        requestId_ = _createRequest(assets_, shares_, owner_);
    }

    /// @notice Override ERC20 _update to call vault rewards before transfers
    /// @dev Calls updateReward on vault rewards contract for from/to addresses
    /// @param from The address tokens are transferred from
    /// @param to The address tokens are transferred to
    /// @param value The amount of tokens transferred
    function _update(address from, address to, uint256 value) internal override {
        address _vaultRewards = _getStakingVaultStorage().vaultRewards;
        if (_vaultRewards != address(0)) {
            if (from != address(0)) {
                IVaultRewards(_vaultRewards).updateReward(from);
            }
            if (to != address(0)) {
                IVaultRewards(_vaultRewards).updateReward(to);
            }
        }
        super._update(from, to, value);
    }

    /*//////////////////////////////////////////////////////////////
                     INTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Check if an account can perform instant withdrawal
    /// @dev Returns true if cooldown is disabled or account is whitelisted
    /// @param account_ The account to check
    /// @return True if the account can withdraw instantly
    function _canInstantWithdraw(address account_) internal view returns (bool) {
        StakingVaultStorage storage $ = _getStakingVaultStorage();
        return !$.cooldownEnabled || $.instantWithdrawWhitelist[account_];
    }

    /*//////////////////////////////////////////////////////////////
                      PRIVATE PURE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the storage pointer for ERC-7201 namespaced storage
    /// @return $ The storage pointer
    function _getStakingVaultStorage() private pure returns (StakingVaultStorage storage $) {
        bytes32 _location = STAKING_VAULT_STORAGE_LOCATION;
        assembly {
            $.slot := _location
        }
    }
}
