// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private _decimals = 6;

    constructor() ERC20("Test token", "TST") {}

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function setDecimals(uint8 decimals_) external {
        _decimals = decimals_;
    }
}
