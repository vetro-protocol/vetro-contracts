// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// forge-lint: disable-next-item(erc20-unchecked-transfer)
contract MockSwapper {
    function swapExactInput(
        address tokenIn_,
        address tokenOut_,
        uint256 amountIn_,
        uint256 amountOutMin_,
        address receiver_
    ) external returns (uint256 _amountOut) {
        require(
            IERC20(tokenIn_).allowance(msg.sender, address(this)) >= amountIn_,
            "MockSwapper: Not enough tokenIn approved"
        );
        IERC20(tokenIn_).transferFrom(msg.sender, address(this), amountIn_);
        _amountOut = amountOutMin_ + 1;

        require(IERC20(tokenOut_).balanceOf(address(this)) >= _amountOut, "MockSwapper: Not enough tokenOut balance");
        IERC20(tokenOut_).transfer(receiver_, _amountOut);
    }
}
