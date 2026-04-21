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
///         Feeds may have different decimal precisions; output decimals are set at deployment.
///         Historical round queries are not supported; only latest-price methods are meaningful
///         for a derived feed whose two sources update on independent schedules.
contract DerivedPriceFeedAdapter is AggregatorV2V3Interface {
    error ZeroAddress();
    error InvalidPrice();
    error OutputDecimalsTooLow();
    error HistoricalRoundsNotSupported();

    /// @notice Chainlink feed for the base asset (e.g. cbBTC/USD).
    AggregatorV2V3Interface public immutable baseFeed;

    /// @notice Chainlink feed for the quote asset, sharing the same intermediate as baseFeed
    ///         (e.g. BTC/USD).
    AggregatorV2V3Interface public immutable quoteFeed;

    uint8 private immutable _decimals;

    /// @dev result = (basePrice * _numeratorScale) / (quotePrice * _denominatorScale)
    ///      _numeratorScale   = 10^(d_quote + d_out)
    ///      _denominatorScale = 10^d_base
    ///      Kept separate to avoid negative exponents when feed decimals differ.
    int256 private immutable _numeratorScale;
    int256 private immutable _denominatorScale;

    /// @param baseFeed_   Chainlink feed for the base asset (e.g. cbBTC/USD, hemiBTC/USD).
    /// @param quoteFeed_  Chainlink feed for the quote asset (e.g. BTC/USD).
    /// @param decimals_   Decimal precision of the derived output feed (minimum 8).
    constructor(AggregatorV2V3Interface baseFeed_, AggregatorV2V3Interface quoteFeed_, uint8 decimals_) {
        if (address(baseFeed_) == address(0) || address(quoteFeed_) == address(0)) revert ZeroAddress();
        if (decimals_ < 8) revert OutputDecimalsTooLow();
        baseFeed = baseFeed_;
        quoteFeed = quoteFeed_;
        _decimals = decimals_;
        _numeratorScale = int256(10 ** uint256(quoteFeed_.decimals() + decimals_));
        _denominatorScale = int256(10 ** uint256(baseFeed_.decimals()));
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
    /// @dev roundId and answeredInRound are always 1 — this feed has no real round system; the
    ///      constant 1 satisfies consumers that check answeredInRound > 0.
    ///      startedAt equals updatedAt (roundAge = 0) because derivation is instantaneous.
    ///      updatedAt is the minimum of both feeds' updatedAt to reflect the least-fresh source.
    function latestRoundData()
        external
        view
        returns (uint80 _roundId, int256 _answer, uint256 _startedAt, uint256 _updatedAt, uint80 _answeredInRound)
    {
        (, int256 _basePrice,, uint256 _baseUpdatedAt,) = baseFeed.latestRoundData();
        (, int256 _quotePrice,, uint256 _quoteUpdatedAt,) = quoteFeed.latestRoundData();
        uint256 _minUpdatedAt = _min(_baseUpdatedAt, _quoteUpdatedAt);
        return (1, _derive(_basePrice, _quotePrice), _minUpdatedAt, _minUpdatedAt, 1);
    }

    /// @inheritdoc AggregatorV3Interface
    /// @dev Not supported: round IDs are independent across two feeds and cannot be correlated.
    function getRoundData(uint80) external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert HistoricalRoundsNotSupported();
    }

    /// @inheritdoc AggregatorInterface
    function latestAnswer() external view returns (int256) {
        (, int256 _basePrice,,,) = baseFeed.latestRoundData();
        (, int256 _quotePrice,,,) = quoteFeed.latestRoundData();
        return _derive(_basePrice, _quotePrice);
    }

    /// @inheritdoc AggregatorInterface
    function latestTimestamp() external view returns (uint256) {
        (,,, uint256 _baseUpdatedAt,) = baseFeed.latestRoundData();
        (,,, uint256 _quoteUpdatedAt,) = quoteFeed.latestRoundData();
        return _min(_baseUpdatedAt, _quoteUpdatedAt);
    }

    /// @inheritdoc AggregatorInterface
    /// @dev Always returns 1 — consistent with the synthetic roundId returned by latestRoundData.
    function latestRound() external pure returns (uint256) {
        return 1;
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

    function _derive(int256 basePrice_, int256 quotePrice_) private view returns (int256 _result) {
        if (basePrice_ <= 0 || quotePrice_ <= 0) revert InvalidPrice();
        _result = (basePrice_ * _numeratorScale) / (quotePrice_ * _denominatorScale);
        if (_result <= 0) revert InvalidPrice();
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
