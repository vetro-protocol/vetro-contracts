// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ProxyImports
 * @notice This file imports OpenZeppelin proxy contracts to ensure they are compiled
 *         and available as artifacts for hardhat-deploy.
 * @dev This file is not meant to be deployed directly.
 */

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
