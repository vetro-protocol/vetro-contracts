// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/// @notice Chainalysis-compatible sanctions list interface (also implemented by the RedStone Sanctions Oracle)
interface ISanctionsList {
    /// @notice True if `account_` must be blocked from minting, redeeming and staking
    function isSanctioned(address account_) external view returns (bool);
}
