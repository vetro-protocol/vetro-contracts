// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface ICurveStableSwapNG {
    function coins(uint256 i) external view returns (address);

    /// @dev EMA price of coin `i + 1` in coin 0, 1e18 precision.
    function price_oracle(uint256 i) external view returns (uint256);

    /// @dev Per-coin rate multipliers, 10^(36 - decimals) for a plain coin.
    function stored_rates() external view returns (uint256[] memory);
}
