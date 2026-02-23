// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

/**
 * @title IYieldDistributor
 * @notice Interface for the YieldDistributor contract
 */
interface IYieldDistributor {
    /**
     * Write Functions
     */

    /// @notice Pull accrued yield to the vault
    /// @return amount The amount of yield pulled
    function pullYield() external returns (uint256 amount);

    /// @notice Distribute yield to the vault over the yield duration
    /// @param amount_ The amount of yield to distribute
    function distribute(uint256 amount_) external;

    /// @notice Rescue tokens accidentally sent to the contract
    /// @param token_ The token to rescue
    /// @param to_ The address to send the tokens to
    /// @param amount_ The amount to rescue
    function rescueTokens(address token_, address to_, uint256 amount_) external;

    /// @notice Update the yield duration period
    /// @param duration_ The new yield duration in seconds
    function updateYieldDuration(uint256 duration_) external;

    /**
     * View Functions
     */

    /// @notice Get the asset token
    /// @return The asset token
    function asset() external view returns (IERC20);

    /// @notice Get the vault address
    /// @return The vault address
    function vault() external view returns (address);

    /// @notice Get pending yield available to pull
    /// @return The amount of pending yield
    function pendingYield() external view returns (uint256);

    /// @notice Get the yield duration period
    /// @return The yield duration in seconds
    function yieldDuration() external view returns (uint256);

    /// @notice Get the current reward rate
    /// @return The reward rate (tokens per second, scaled by 1e18)
    function rewardRate() external view returns (uint256);

    /// @notice Get the period finish timestamp
    /// @return The timestamp when current distribution ends
    function periodFinish() external view returns (uint256);

    /// @notice Get the last update timestamp
    /// @return The timestamp of last yield pull
    function lastUpdateTime() external view returns (uint256);
}
