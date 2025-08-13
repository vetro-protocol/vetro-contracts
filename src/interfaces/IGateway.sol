// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IVUSD} from "./IVUSD.sol";

/// @title IGateway - Interface for VUSD Gateway
interface IGateway {
    /**
     * Write Functions
     */
    function mint(address token_, uint256 amountIn_, uint256 minVusdOut_, address receiver_)
        external
        returns (uint256);
    function redeem(address token_, uint256 vusdAmount_, uint256 minAmountOut_, address tokenReceiver_) external;

    /**
     * View Functions
     */
    function NAME() external view returns (string memory);
    function VERSION() external view returns (string memory);
    function MAX_BPS() external view returns (uint256);

    function maxMintable() external view returns (uint256);
    function mintable(address token_, uint256 amountIn_) external view returns (uint256);
    function mintFee() external view returns (uint256);
    function mintLimit() external view returns (uint256);
    function owner() external view returns (address);
    function redeemableOf(address token_) external view returns (uint256);
    function redeemable(address token_, uint256 vusdAmount_) external view returns (uint256);
    function redeemFee() external view returns (uint256);
    function treasury() external view returns (address);
    function vusd() external view returns (IVUSD);
}
