// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPeggedToken} from "./IPeggedToken.sol";

/// @title ITreasury - Interface for PeggedToken Treasury
interface ITreasury {
    /**
     * Write Functions
     */
    function deposit(address token_, uint256 amount_) external;
    function withdraw(address token_, uint256 amount_, address tokenReceiver_) external;

    /**
     * View Functions
     */
    function hasRole(bytes32 role, address account) external view returns (bool);
    function gateway() external view returns (address);
    function getPrice(address token_) external view returns (uint256 _latestPrice, uint256 _unitPrice);
    function isWhitelistedToken(address token_) external view returns (bool);
    function owner() external view returns (address);
    function reserve() external view returns (uint256 _reserve);
    function withdrawable(address token_) external view returns (uint256);
    function PEGGED_TOKEN() external view returns (IPeggedToken);
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function UMM_ROLE() external view returns (bytes32);
    function MAINTAINER_ROLE() external view returns (bytes32);
}
