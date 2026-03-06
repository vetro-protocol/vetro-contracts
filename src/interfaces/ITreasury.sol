// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPeggedToken} from "./IPeggedToken.sol";

/// @title ITreasury - Interface for PeggedToken Treasury
/// @dev hasRole(), DEFAULT_ADMIN_ROLE(), and getRoleAdmin() are inherited from AccessControl via
///      AccessControlDefaultAdminRules and therefore not repeated here.
interface ITreasury {
    function addToWhitelist(address token_, address vault_, address oracle_, uint256 stalePeriod_) external;
    function deposit(address token_, uint256 amount_) external;
    function gateway() external view returns (address);
    function getPrice(address token_) external view returns (uint256 _latestPrice, uint256 _unitPrice);
    function harvest(address token_, address receiver_) external returns (uint256);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function isWhitelistedToken(address token_) external view returns (bool);
    // solhint-disable-next-line func-name-mixedcase
    function MAINTAINER_ROLE() external view returns (bytes32);
    function migrate(address newTreasury_) external;
    function owner() external view returns (address);
    // solhint-disable-next-line func-name-mixedcase
    function PEGGED_TOKEN() external view returns (IPeggedToken);
    function priceTolerance() external view returns (uint256);
    function pull(address token_, uint256 amount_) external;
    function push(address token_, uint256 amount_) external;
    function removeFromWhitelist(address token_) external;
    function reserve() external view returns (uint256 _reserve);
    function setDepositActive(address token_, bool active_) external;
    function setWithdrawActive(address token_, bool active_) external;
    function swap(address tokenIn_, address tokenOut_, uint256 amountIn_, uint256 minAmountOut_)
        external
        returns (uint256);
    function sweep(address fromToken_, address receiver_) external;
    // solhint-disable-next-line func-name-mixedcase
    function UMM_ROLE() external view returns (bytes32);
    function updateOracle(address token_, address oracle_, uint256 newStalePeriod_) external;
    function updatePriceTolerance(uint256 newPriceTolerance_) external;
    function updateSwapper(address swapper_) external;
    function whitelistedTokens() external view returns (address[] memory);
    function withdraw(address token_, uint256 amount_, address tokenReceiver_) external;
    function withdrawable(address token_) external view returns (uint256);
}
