// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private _decimals = 6;
    bool private _hasFeeOnTransfer = false;

    constructor() ERC20("Test token", "TST") {}

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function setDecimals(uint8 decimals_) external {
        _decimals = decimals_;
    }

    function setHasFeeOnTransfer(bool hasFeeOnTransfer_) external {
        _hasFeeOnTransfer = hasFeeOnTransfer_;
    }

    // Skim a flat 1 unit fee on any transfer to simulate fee-on-transfer tokens
    function _update(address from, address to, uint256 value) internal virtual override {
        if (_hasFeeOnTransfer) {
            if (from != address(0) && to != address(0) && value > 0) {
                uint256 fee = 1;
                if (value > fee) {
                    super._update(from, address(0), fee); // burn fee
                    value -= fee;
                }
            }
        }
        super._update(from, to, value);
    }
}
