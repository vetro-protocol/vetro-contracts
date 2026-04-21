// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {
    AggregatorInterface,
    AggregatorV3Interface,
    AggregatorV2V3Interface
} from "@chainlink/contracts/interfaces/feeds/AggregatorV2V3Interface.sol";

/// @title FixedPriceFeedAdapter
/// @notice Returns a hardcoded price, implementing the full Chainlink AggregatorV2V3Interface.
///         Intended for assets whose on-chain price is fixed at a known ratio,
///         e.g. WBTC/BTC = 1.0 (WBTC is a 1:1 wrapped representation of BTC).
///         updatedAt always returns block.timestamp — the price is current by definition.
contract FixedPriceFeedAdapter is AggregatorV2V3Interface {
    error InvalidPrice();

    int256 private immutable _price;
    uint8 private immutable _decimals;
    string private _description;

    /// @param price_       Fixed price value (e.g. 1e8 for 1.0 at 8-decimal precision).
    /// @param decimals_    Decimal precision matching the feed ecosystem (e.g. 8 for BTC feeds).
    /// @param description_ Human-readable label (e.g. "WBTC / BTC").
    constructor(int256 price_, uint8 decimals_, string memory description_) {
        if (price_ <= 0) revert InvalidPrice();
        _price = price_;
        _decimals = decimals_;
        _description = description_;
    }

    /// @inheritdoc AggregatorV3Interface
    function decimals() external view returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc AggregatorV3Interface
    function description() external view returns (string memory) {
        return _description;
    }

    /// @inheritdoc AggregatorV3Interface
    function version() external pure returns (uint256) {
        return 1;
    }

    /// @inheritdoc AggregatorV3Interface
    /// @dev roundId and answeredInRound are always 1 — satisfies answeredInRound > 0.
    ///      startedAt equals updatedAt (roundAge = 0) — the fixed price is always current by definition.
    function latestRoundData()
        external
        view
        returns (uint80 _roundId, int256 _answer, uint256 _startedAt, uint256 _updatedAt, uint80 _answeredInRound)
    {
        return (1, _price, block.timestamp, block.timestamp, 1);
    }

    /// @inheritdoc AggregatorV3Interface
    /// @dev All historical rounds return the same fixed price; startedAt equals updatedAt.
    function getRoundData(uint80 roundId_)
        external
        view
        returns (uint80 _roundId, int256 _answer, uint256 _startedAt, uint256 _updatedAt, uint80 _answeredInRound)
    {
        return (roundId_, _price, block.timestamp, block.timestamp, roundId_);
    }

    /// @inheritdoc AggregatorInterface
    function latestAnswer() external view returns (int256) {
        return _price;
    }

    /// @inheritdoc AggregatorInterface
    function latestTimestamp() external view returns (uint256) {
        return block.timestamp;
    }

    /// @inheritdoc AggregatorInterface
    /// @dev Always returns 1 — consistent with the roundId returned by latestRoundData.
    function latestRound() external pure returns (uint256) {
        return 1;
    }

    /// @inheritdoc AggregatorInterface
    function getAnswer(uint256) external view returns (int256) {
        return _price;
    }

    /// @inheritdoc AggregatorInterface
    function getTimestamp(uint256) external view returns (uint256) {
        return block.timestamp;
    }
}
