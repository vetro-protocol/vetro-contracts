// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ISanctionsList} from "src/interfaces/ISanctionsList.sol";

contract MockSanctionsList is ISanctionsList {
    mapping(address => bool) public isSanctioned;

    function setSanctioned(address account_, bool status_) external {
        isSanctioned[account_] = status_;
    }
}
