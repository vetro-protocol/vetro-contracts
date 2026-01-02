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
    function gateway() external view returns (address);
    function getPrice(address token_) external view returns (uint256 _latestPrice, uint256 _unitPrice);
    function isWhitelistedToken(address token_) external view returns (bool);
    function reserve() external view returns (uint256 _reserve);
    /// forge-lint: disable-next-line(mixed-case-function)
    function PEGGED_TOKEN() external view returns (IPeggedToken);
    function withdrawable(address token_) external view returns (uint256);
}
