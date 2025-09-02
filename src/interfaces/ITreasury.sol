// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IVUSD} from "./IVUSD.sol";

/// @title ITreasury - Interface for VUSD Treasury
interface ITreasury {
    /**
     * Write Functions
     */
    function deposit(address token_, uint256 amount_) external;
    function withdraw(address token_, uint256 amount_, address tokenReceiver_) external;

    /**
     * View Functions
     */
    function gateway() external view returns (address);
    function getPrice(address token_) external view returns (uint256 _latestPrice, uint256 _unitPrice);
    function isWhitelistedToken(address token_) external view returns (bool);
    function vusd() external view returns (IVUSD);
    function withdrawable(address token_) external view returns (uint256);
}
