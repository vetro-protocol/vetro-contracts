// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IPeggedToken} from "./IPeggedToken.sol";

/**
 * @title ISpoke - What the Gateway needs from a spoke
 * @notice A spoke is an isolated minter hanging off the Gateway (the hub). It is its own entry point: it takes its
 * collateral, prices it, applies its own access rules, and asks the Gateway to mint or burn the pegged token. The
 * Gateway caps each spoke's supply and values it through `reserve()`.
 */
interface ISpoke {
    /// @notice Pegged token the Gateway mints against this spoke
    function peggedToken() external view returns (IPeggedToken);

    /// @notice Value of the spoke's collateral, in pegged token units. The Gateway refuses a mint that leaves it below
    /// the spoke's supply.
    function reserve() external view returns (uint256);
}
