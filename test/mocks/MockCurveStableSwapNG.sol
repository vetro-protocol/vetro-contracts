// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @dev The StableSwap-NG views the EMA adapter reads: coins, EMA prices against coin 0 and per-coin rates.
///      Rates start as a plain pool's 10^(36 - decimals).
contract MockCurveStableSwapNG {
    address[] private _coins;
    uint256[] private _rates;
    mapping(uint256 => uint256) private _priceOracle;

    constructor(address[] memory coins_) {
        _coins = coins_;
        for (uint256 i; i < coins_.length; ++i) {
            _rates.push(10 ** (36 - uint256(IERC20Metadata(coins_[i]).decimals())));
            if (i > 0) _priceOracle[i - 1] = 1e18;
        }
    }

    /// @dev Reverts past the last coin, like the pool.
    function coins(uint256 i) external view returns (address) {
        return _coins[i];
    }

    function price_oracle(uint256 i) external view returns (uint256) {
        return _priceOracle[i];
    }

    function stored_rates() external view returns (uint256[] memory) {
        return _rates;
    }

    function setPriceOracle(uint256 i, uint256 price_) external {
        _priceOracle[i] = price_;
    }

    function setRate(uint256 i, uint256 rate_) external {
        _rates[i] = rate_;
    }
}
