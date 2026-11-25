// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {
    AggregatorInterface,
    AggregatorV3Interface,
    AggregatorV2V3Interface
} from "@chainlink/contracts/interfaces/feeds/AggregatorV2V3Interface.sol";

/// @title MinPriceFeedAdapter
/// @notice Lower of two feeds pricing the same asset in the same unit: min(feedA, feedB).
///         Reverts if the difference between the feeds is more than maxDeviation of the higher feed.
///         E.g. cbBTC/WBTC = min(Chainlink cbBTC/WBTC, Curve EMA cbBTC/WBTC), so a market discount Chainlink
///         cannot see still lowers the price, but feeds that diverge more than maxDeviation stop the feed.
///         With maxDeviation at 100% there is no bound.
///         Feeds may have different decimal precisions; output decimals are set at deployment.
///         Historical round queries are not supported.
contract MinPriceFeedAdapter is AggregatorV2V3Interface {
    error ZeroAddress();
    error InvalidPrice();
    error OutputDecimalsTooLow();
    error MaxDeviationTooHigh();
    error MaxDeviationExceeded();
    error HistoricalRoundsNotSupported();

    uint256 private constant MAX_BPS = 10_000;

    /// @notice Reference source (e.g. the primary Chainlink feed).
    AggregatorV2V3Interface public immutable feedA;

    /// @notice Second source (e.g. CurveStableSwapNGEmaFeedAdapter).
    AggregatorV2V3Interface public immutable feedB;

    /// @notice Maximum difference between the feeds, in bps of the higher feed.
    uint256 public immutable maxDeviation;

    uint8 private immutable _decimals;

    /// @dev Each answer is scaled to d_out as answer * 10^d_out / 10^d_feed; kept as two factors per feed
    ///      so a feed with more decimals than the output is scaled down without a negative exponent.
    int256 private immutable _scaleUp;
    int256 private immutable _scaleDownA;
    int256 private immutable _scaleDownB;

    /// @param feedA_        Reference feed.
    /// @param feedB_        Second feed, same asset and unit as feedA_.
    /// @param decimals_     Decimal precision of the output feed (minimum 8).
    /// @param maxDeviation_ Maximum difference between the feeds, in bps of the higher feed (10000 = no bound).
    constructor(
        AggregatorV2V3Interface feedA_,
        AggregatorV2V3Interface feedB_,
        uint8 decimals_,
        uint256 maxDeviation_
    ) {
        if (address(feedA_) == address(0) || address(feedB_) == address(0)) revert ZeroAddress();
        if (decimals_ < 8) revert OutputDecimalsTooLow();
        if (maxDeviation_ > MAX_BPS) revert MaxDeviationTooHigh();
        feedA = feedA_;
        feedB = feedB_;
        maxDeviation = maxDeviation_;
        _decimals = decimals_;
        _scaleUp = int256(10 ** uint256(decimals_));
        _scaleDownA = int256(10 ** uint256(feedA_.decimals()));
        _scaleDownB = int256(10 ** uint256(feedB_.decimals()));
    }

    /// @inheritdoc AggregatorV3Interface
    function decimals() external view returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc AggregatorV3Interface
    function description() external view returns (string memory) {
        return string.concat("min(", feedA.description(), ", ", feedB.description(), ")");
    }

    /// @inheritdoc AggregatorV3Interface
    function version() external pure returns (uint256) {
        return 1;
    }

    /// @inheritdoc AggregatorV3Interface
    /// @dev roundId and answeredInRound are always 1, as in DerivedPriceFeedAdapter.
    ///      updatedAt is the minimum of both feeds' updatedAt to reflect the least-fresh source: a stale feed
    ///      is reported stale even when the other one is the lower answer.
    function latestRoundData()
        external
        view
        returns (uint80 _roundId, int256 _answer, uint256 _startedAt, uint256 _updatedAt, uint80 _answeredInRound)
    {
        (, int256 _priceA,, uint256 _updatedAtA,) = feedA.latestRoundData();
        (, int256 _priceB,, uint256 _updatedAtB,) = feedB.latestRoundData();
        uint256 _minUpdatedAt = _updatedAtA < _updatedAtB ? _updatedAtA : _updatedAtB;
        return (1, _lower(_priceA, _priceB), _minUpdatedAt, _minUpdatedAt, 1);
    }

    /// @inheritdoc AggregatorV3Interface
    /// @dev Not supported: round IDs are independent across two feeds and cannot be correlated.
    function getRoundData(uint80) external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert HistoricalRoundsNotSupported();
    }

    /// @inheritdoc AggregatorInterface
    function latestAnswer() external view returns (int256) {
        (, int256 _priceA,,,) = feedA.latestRoundData();
        (, int256 _priceB,,,) = feedB.latestRoundData();
        return _lower(_priceA, _priceB);
    }

    /// @inheritdoc AggregatorInterface
    function latestTimestamp() external view returns (uint256) {
        (,,, uint256 _updatedAtA,) = feedA.latestRoundData();
        (,,, uint256 _updatedAtB,) = feedB.latestRoundData();
        return _updatedAtA < _updatedAtB ? _updatedAtA : _updatedAtB;
    }

    /// @inheritdoc AggregatorInterface
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

    /// @dev Reverts on a non-positive source rather than returning the other: a broken source must not be
    ///      silently dropped from the min(). Reverts if the feeds diverge more than maxDeviation.
    function _lower(int256 priceA_, int256 priceB_) private view returns (int256 _result) {
        if (priceA_ <= 0 || priceB_ <= 0) revert InvalidPrice();
        int256 _a = (priceA_ * _scaleUp) / _scaleDownA;
        int256 _b = (priceB_ * _scaleUp) / _scaleDownB;
        (int256 _high, int256 _low) = _a > _b ? (_a, _b) : (_b, _a);
        if ((_high - _low) * int256(MAX_BPS) > _high * int256(maxDeviation)) revert MaxDeviationExceeded();
        _result = _low;
        if (_result <= 0) revert InvalidPrice();
    }
}
