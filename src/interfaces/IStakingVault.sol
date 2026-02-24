// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title IStakingVault
 * @notice Interface for the staking vault
 */
interface IStakingVault is IERC4626 {
    /// @notice Cooldown request details
    struct CooldownRequest {
        address owner;
        uint256 assets;
        uint256 claimableAt;
    }

    /*//////////////////////////////////////////////////////////////
                         COOLDOWN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Request a redemption with cooldown (specify shares to burn)
    /// @param shares_ The amount of shares to redeem
    /// @param owner_ The owner of the shares (requires allowance if not msg.sender)
    /// @return requestId The globally unique ID of the cooldown request
    /// @return assets The amount of assets that will be claimable
    function requestRedeem(uint256 shares_, address owner_) external returns (uint256 requestId, uint256 assets);

    /// @notice Request a withdrawal with cooldown (specify assets to receive)
    /// @param assets_ The amount of assets to withdraw
    /// @param owner_ The owner of the shares (requires allowance if not msg.sender)
    /// @return requestId The globally unique ID of the cooldown request
    /// @return shares The amount of shares that were burned
    function requestWithdraw(uint256 assets_, address owner_) external returns (uint256 requestId, uint256 shares);

    /// @notice Claim a matured withdrawal request
    /// @param requestId_ The ID of the request to claim
    /// @param receiver_ The address to receive the assets
    /// @return assets The amount of assets claimed
    function claimWithdraw(uint256 requestId_, address receiver_) external returns (uint256 assets);

    /// @notice Claim multiple matured withdrawal requests
    /// @param requestIds_ The IDs of the requests to claim
    /// @param receiver_ The address to receive the assets
    /// @return totalAssets The total amount of assets claimed
    function claimWithdrawBatch(uint256[] calldata requestIds_, address receiver_)
        external
        returns (uint256 totalAssets);

    /// @notice Cancel a pending withdrawal request
    /// @dev Only the request owner can cancel
    /// @param requestId_ The ID of the request to cancel
    /// @return shares The amount of shares returned to owner
    function cancelWithdraw(uint256 requestId_) external returns (uint256 shares);

    /*//////////////////////////////////////////////////////////////
                         ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Update the yield distributor address
    /// @param distributor_ The new yield distributor address
    function updateYieldDistributor(address distributor_) external;

    /// @notice Update the vault rewards contract address
    /// @param vaultRewards_ The new vault rewards address
    function updateVaultRewards(address vaultRewards_) external;

    /// @notice Update instant withdraw whitelist status for an account
    /// @param account_ The account to update
    /// @param status_ The new whitelist status
    function updateInstantWithdrawWhitelist(address account_, bool status_) external;

    /// @notice Update cooldown enabled status
    /// @param enabled_ The new cooldown enabled status
    function updateCooldownEnabled(bool enabled_) external;

    /// @notice Update cooldown duration
    /// @param duration_ The new cooldown duration in seconds
    function updateCooldownDuration(uint256 duration_) external;

    /*//////////////////////////////////////////////////////////////
                           VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get all active request IDs for an account
    /// @param account_ The account to query
    /// @return requestIds Array of active request IDs
    function getActiveRequestIds(address account_) external view returns (uint256[] memory requestIds);

    /// @notice Get all claimable requests for an account
    /// @param account_ The account to query
    /// @return requestIds Array of claimable request IDs
    /// @return assets Array of asset amounts for each request
    function getClaimableRequests(address account_)
        external
        view
        returns (uint256[] memory requestIds, uint256[] memory assets);

    /// @notice Get all pending (not yet matured) requests for an account
    /// @param account_ The account to query
    /// @return requestIds Array of pending request IDs
    /// @return assets Array of asset amounts for each request
    /// @return claimableAt Array of claimable timestamps for each request
    function getPendingRequests(address account_)
        external
        view
        returns (uint256[] memory requestIds, uint256[] memory assets, uint256[] memory claimableAt);

    /// @notice Get details of a specific cooldown request
    /// @param requestId_ The ID of the request
    /// @return request The cooldown request details
    function getRequestDetails(uint256 requestId_) external view returns (CooldownRequest memory request);

    /// @notice Get the next global request ID
    /// @return The next request ID that will be assigned
    function nextRequestId() external view returns (uint256);

    /// @notice Get the yield distributor address
    /// @return The yield distributor address
    function yieldDistributor() external view returns (address);

    /// @notice Get the vault rewards contract address
    /// @return The vault rewards address
    function vaultRewards() external view returns (address);

    /// @notice Get the cooldown duration
    /// @return The cooldown duration in seconds
    function cooldownDuration() external view returns (uint256);

    /// @notice Check if cooldown is enabled
    /// @return True if cooldown is enabled
    function cooldownEnabled() external view returns (bool);

    /// @notice Get total assets currently in cooldown
    /// @return The total assets in cooldown
    function totalAssetsInCooldown() external view returns (uint256);

    /// @notice Check if an address is whitelisted for instant withdraw
    /// @param account_ The address to check
    /// @return True if whitelisted
    function instantWithdrawWhitelist(address account_) external view returns (bool);
}
