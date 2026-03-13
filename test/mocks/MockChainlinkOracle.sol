// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AggregatorV2V3Interface} from "@chainlink/contracts/interfaces/feeds/AggregatorV2V3Interface.sol";

contract MockChainlinkOracle is AggregatorV2V3Interface {
    int256 private price;
    uint256 updatedAt = block.timestamp;

    constructor(int256 _price) {
        price = _price;
    }

    function updatePrice(int256 _price) external {
        price = _price;
        updatedAt = block.timestamp;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "Mock Chainlink Oracle";
    }

    function version() external pure returns (uint256) {
        return 2;
    }

    function getRoundData(uint80 roundId_)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt_, uint80 answeredInRound)
    {
        return (roundId_, price, 0, updatedAt, 0);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt_, uint80 answeredInRound)
    {
        return (0, price, 0, updatedAt, 0);
    }

    function latestAnswer() external pure returns (int256) {
        return 10;
    }

    function latestTimestamp() external pure returns (uint256) {
        return 20;
    }

    function latestRound() external pure returns (uint256) {
        return 30;
    }

    function getAnswer(uint256 roundId) external pure returns (int256) {
        return 40;
    }

    function getTimestamp(uint256 roundId) external pure returns (uint256) {
        return 50;
    }
}
