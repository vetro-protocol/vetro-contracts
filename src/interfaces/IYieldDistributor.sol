// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title IYieldDistributor
 * @notice Interface for the YieldDistributor contract
 */
interface IYieldDistributor {
    /// @notice Pull accrued yield to the vault
    /// @return amount The amount of yield pulled
    function pullYield() external returns (uint256 amount);

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
