// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

/// @title IPeggedToken - Interface for PeggedToken stablecoin
interface IPeggedToken is IERC20 {
    /**
     * Write Functions
     */
    function burnFrom(address account_, uint256 amount_) external;
    function mint(address account_, uint256 amount_) external;

    /**
     * View Functions
     */
    function gateway() external view returns (address _gateway);
    function owner() external view returns (address _owner);
    function treasury() external view returns (address _treasury);
}
