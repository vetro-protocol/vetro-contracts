// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPeggedToken} from "./IPeggedToken.sol";

/// @title ITreasury - Interface for PeggedToken Treasury
/// @dev hasRole(), DEFAULT_ADMIN_ROLE(), and getRoleAdmin() are inherited from AccessControl via
///      AccessControlDefaultAdminRules and therefore not repeated here.
interface ITreasury {
    /**
     * Write Functions
     */
    function addToWhitelist(address token_, address vault_, address oracle_, uint256 stalePeriod_) external;
    function removeFromWhitelist(address token_) external;
    function migrate(address newTreasury_) external;
    function sweep(address fromToken_, address receiver_) external;
    function updateOracle(address token_, address oracle_, uint256 newStalePeriod_) external;
    function updatePriceTolerance(uint256 newPriceTolerance_) external;
    function updateSwapper(address swapper_) external;
    function deposit(address token_, uint256 amount_) external;
    function withdraw(address token_, uint256 amount_, address tokenReceiver_) external;
    function push(address token_, uint256 amount_) external;
    function pull(address token_, uint256 amount_) external;
    function setDepositActive(address token_, bool active_) external;
    function setWithdrawActive(address token_, bool active_) external;
    function swap(address tokenIn_, address tokenOut_, uint256 amountIn_, uint256 minAmountOut_)
        external
        returns (uint256);
    function harvest(address token_, address receiver_) external returns (uint256);

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
    function whitelistedTokens() external view returns (address[] memory);
    // solhint-disable-next-line func-name-mixedcase
    function PEGGED_TOKEN() external view returns (IPeggedToken);
    // solhint-disable-next-line func-name-mixedcase
    function UMM_ROLE() external view returns (bytes32);
    // solhint-disable-next-line func-name-mixedcase
    function MAINTAINER_ROLE() external view returns (bytes32);
}
