// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Treasury} from "src/Treasury.sol";

/// @dev Deploys a Treasury behind a proxy. Nobody but `admin_` holds a role until the admin grants one.
function deployTreasury(address peggedToken_, address admin_) returns (Treasury) {
    bytes memory _initData = abi.encodeCall(Treasury.initialize, (peggedToken_, admin_));
    return Treasury(address(new ERC1967Proxy(address(new Treasury()), _initData)));
}
