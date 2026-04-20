// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {
    AggregatorInterface,
    AggregatorV3Interface,
    AggregatorV2V3Interface
} from "@chainlink/contracts/interfaces/feeds/AggregatorV2V3Interface.sol";

/// @title DerivedPriceFeedAdapter
/// @notice Derives a base/quote price from two Chainlink feeds that share a common intermediate:
///         base/quote = (base/X) / (quote/X)
///         E.g. cbBTC/BTC from cbBTC/USD and BTC/USD, or hemiBTC/BTC from hemiBTC/USD and BTC/USD.
///         Both feeds must have the same decimal precision.
///         Historical round queries are not supported; only latest-price methods are meaningful
///         for a derived feed whose two sources update on independent schedules.
contract DerivedPriceFeedAdapter is AggregatorV2V3Interface {
    error ZeroAddress();
    error FeedDecimalsMismatch();
    error InvalidPrice();
    error HistoricalRoundsNotSupported();

    /// @notice Chainlink feed for the base asset (e.g. cbBTC/USD).
    AggregatorV2V3Interface public immutable baseFeed;

    /// @notice Chainlink feed for the quote asset, sharing the same intermediate as baseFeed
    ///         (e.g. BTC/USD).
    AggregatorV2V3Interface public immutable quoteFeed;

    uint8 private immutable _decimals;

    /// @param baseFeed_  Chainlink feed for the base asset (e.g. cbBTC/USD, hemiBTC/USD).
    /// @param quoteFeed_ Chainlink feed for the quote asset (e.g. BTC/USD).
    constructor(AggregatorV2V3Interface baseFeed_, AggregatorV2V3Interface quoteFeed_) {
        if (address(baseFeed_) == address(0) || address(quoteFeed_) == address(0)) revert ZeroAddress();
        uint8 baseDecimals = baseFeed_.decimals();
        if (baseDecimals != quoteFeed_.decimals()) revert FeedDecimalsMismatch();
        baseFeed = baseFeed_;
        quoteFeed = quoteFeed_;
        _decimals = baseDecimals;
    }

    /// @inheritdoc AggregatorV3Interface
    function decimals() external view returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc AggregatorV3Interface
    function description() external view returns (string memory) {
        return string.concat(baseFeed.description(), " / ", quoteFeed.description(), " derived");
    }

    /// @inheritdoc AggregatorV3Interface
    function version() external pure returns (uint256) {
        return 1;
    }

    /// @inheritdoc AggregatorV3Interface
    /// @dev roundId and answeredInRound are always 0 — this feed has no round system; the price
    ///      is derived on-the-fly from two independent feeds that update on different schedules.
    ///      updatedAt is the minimum of both feeds' updatedAt to reflect the least-fresh source.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (, int256 basePrice,, uint256 baseUpdatedAt,) = baseFeed.latestRoundData();
        (, int256 quotePrice,, uint256 quoteUpdatedAt,) = quoteFeed.latestRoundData();
        return (0, _derive(basePrice, quotePrice), 0, _min(baseUpdatedAt, quoteUpdatedAt), 0);
    }

    /// @inheritdoc AggregatorV3Interface
    /// @dev Not supported: round IDs are independent across two feeds and cannot be correlated.
    function getRoundData(uint80) external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert HistoricalRoundsNotSupported();
    }

    /// @inheritdoc AggregatorInterface
    function latestAnswer() external view returns (int256) {
        (, int256 basePrice,,,) = baseFeed.latestRoundData();
        (, int256 quotePrice,,,) = quoteFeed.latestRoundData();
        return _derive(basePrice, quotePrice);
    }

    /// @inheritdoc AggregatorInterface
    function latestTimestamp() external view returns (uint256) {
        (,,, uint256 baseUpdatedAt,) = baseFeed.latestRoundData();
        (,,, uint256 quoteUpdatedAt,) = quoteFeed.latestRoundData();
        return _min(baseUpdatedAt, quoteUpdatedAt);
    }

    /// @inheritdoc AggregatorInterface
    /// @dev Always returns 0 — this feed has no round system.
    function latestRound() external pure returns (uint256) {
        return 0;
    }

    /// @inheritdoc AggregatorInterface
    /// @dev Not supported: round IDs are independent across two feeds and cannot be correlated.
    function getAnswer(uint256) external pure returns (int256) {
        revert HistoricalRoundsNotSupported();
    }

    /// @inheritdoc AggregatorInterface
    /// @dev Not supported: round IDs are independent across two feeds and cannot be correlated.
    function getTimestamp(uint256) external pure returns (uint256) {
        revert HistoricalRoundsNotSupported();
    }

    function _derive(int256 basePrice_, int256 quotePrice_) private view returns (int256) {
        if (basePrice_ <= 0 || quotePrice_ <= 0) revert InvalidPrice();
        return (basePrice_ * int256(10 ** uint256(_decimals))) / quotePrice_;
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
