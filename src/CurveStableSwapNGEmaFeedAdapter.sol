// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {
    AggregatorInterface,
    AggregatorV3Interface,
    AggregatorV2V3Interface
} from "@chainlink/contracts/interfaces/feeds/AggregatorV2V3Interface.sol";

interface ICurveStableSwapNG {
    function coins(uint256 i) external view returns (address);

    /// @dev EMA price of coin `i + 1` in coin 0, 1e18 precision.
    function price_oracle(uint256 i) external view returns (uint256);
}

/// @title CurveStableSwapNGEmaFeedAdapter
/// @notice Market price of one Curve StableSwap-NG pool coin in the peg unit, quoted through another coin of
///         the same pool:
///         base/peg = EMA(base/quote) * quote/peg,  EMA(base/quote) = P_base / P_quote
///         where P_k is the pool's EMA price of coin k in coin 0 (P_0 = 1).
///         E.g. hemiBTC/BTC from the WBTC/cbBTC/hemiBTC pool as EMA(hemiBTC/WBTC) x Chainlink WBTC/BTC.
///         Uses the pool's EMA, never spot: Curve folds a trade into the EMA only on the first interaction of a
///         later block, so a same-block sandwich cannot move this price.
///         Meant to be paired with the token's primary feed through `MinPriceFeedAdapter`: the EMA lags a real
///         move by roughly the pool's `ma_exp_time`, so on its own it only lowers a price, it does not bound it.
///         Historical round queries are not supported.
/// @dev Only for plain-coin pools: with a rate-oracle or ERC-4626 coin (e.g. weETH) the NG EMA is in
///      rate-adjusted terms and would read ~1.0 instead of the market price. The EMA is 1e18 per whole token
///      whatever the coin decimals.
contract CurveStableSwapNGEmaFeedAdapter is AggregatorV2V3Interface {
    error ZeroAddress();
    error InvalidPrice();
    error SameCoin();
    error CoinMismatch();
    error HistoricalRoundsNotSupported();

    /// @notice Curve StableSwap-NG pool holding both coins.
    ICurveStableSwapNG public immutable pool;

    /// @notice Pool index of the priced coin.
    uint256 public immutable baseIndex;

    /// @notice Pool index of the coin the EMA is quoted in; priced in the peg unit by `quoteFeed`.
    uint256 public immutable quoteIndex;

    /// @notice Chainlink feed pricing the quote coin in the peg unit (e.g. WBTC/BTC).
    AggregatorV2V3Interface public immutable quoteFeed;

    uint256 private immutable _quoteFeedUnit;

    /// @param pool_        Curve StableSwap-NG pool.
    /// @param baseToken_   Coin to price; must be `pool_.coins(baseIndex_)`.
    /// @param baseIndex_   Index of `baseToken_` in the pool.
    /// @param quoteToken_  Coin the EMA is quoted in; must be `pool_.coins(quoteIndex_)` and be what `quoteFeed_`
    ///                     prices.
    /// @param quoteIndex_  Index of `quoteToken_` in the pool.
    /// @param quoteFeed_   Chainlink feed for the quote coin in the peg unit.
    constructor(
        ICurveStableSwapNG pool_,
        address baseToken_,
        uint256 baseIndex_,
        address quoteToken_,
        uint256 quoteIndex_,
        AggregatorV2V3Interface quoteFeed_
    ) {
        if (
            address(pool_) == address(0) || baseToken_ == address(0) || quoteToken_ == address(0)
                || address(quoteFeed_) == address(0)
        ) revert ZeroAddress();
        if (baseIndex_ == quoteIndex_) revert SameCoin();
        // coins() reverts on an index past the last coin
        if (pool_.coins(baseIndex_) != baseToken_ || pool_.coins(quoteIndex_) != quoteToken_) revert CoinMismatch();
        pool = pool_;
        baseIndex = baseIndex_;
        quoteIndex = quoteIndex_;
        quoteFeed = quoteFeed_;
        _quoteFeedUnit = 10 ** uint256(quoteFeed_.decimals());
    }

    /// @inheritdoc AggregatorV3Interface
    function decimals() external pure returns (uint8) {
        return 18;
    }

    /// @inheritdoc AggregatorV3Interface
    function description() external view returns (string memory) {
        return string.concat("Curve EMA x ", quoteFeed.description());
    }

    /// @inheritdoc AggregatorV3Interface
    function version() external pure returns (uint256) {
        return 1;
    }

    /// @inheritdoc AggregatorV3Interface
    /// @dev roundId and answeredInRound are always 1, as in DerivedPriceFeedAdapter.
    ///      updatedAt is quoteFeed's: the EMA carries no timestamp of its own (it holds the last traded
    ///      price while the pool is idle), so staleness is enforced on the Chainlink leg only.
    function latestRoundData()
        external
        view
        returns (uint80 _roundId, int256 _answer, uint256 _startedAt, uint256 _updatedAt, uint80 _answeredInRound)
    {
        (, int256 _quotePrice,, uint256 _quoteUpdatedAt,) = quoteFeed.latestRoundData();
        return (1, _derive(_quotePrice), _quoteUpdatedAt, _quoteUpdatedAt, 1);
    }

    /// @inheritdoc AggregatorV3Interface
    /// @dev Not supported: the Curve EMA has no rounds.
    function getRoundData(uint80) external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert HistoricalRoundsNotSupported();
    }

    /// @inheritdoc AggregatorInterface
    function latestAnswer() external view returns (int256) {
        (, int256 _quotePrice,,,) = quoteFeed.latestRoundData();
        return _derive(_quotePrice);
    }

    /// @inheritdoc AggregatorInterface
    function latestTimestamp() external view returns (uint256) {
        (,,, uint256 _quoteUpdatedAt,) = quoteFeed.latestRoundData();
        return _quoteUpdatedAt;
    }

    /// @inheritdoc AggregatorInterface
    function latestRound() external pure returns (uint256) {
        return 1;
    }

    /// @inheritdoc AggregatorInterface
    /// @dev Not supported: the Curve EMA has no rounds.
    function getAnswer(uint256) external pure returns (int256) {
        revert HistoricalRoundsNotSupported();
    }

    /// @inheritdoc AggregatorInterface
    /// @dev Not supported: the Curve EMA has no rounds.
    function getTimestamp(uint256) external pure returns (uint256) {
        revert HistoricalRoundsNotSupported();
    }

    /// @notice EMA price of the base coin in the quote coin, 1e18 precision.
    function emaRatio() public view returns (uint256) {
        uint256 _base = _priceInCoin0(baseIndex);
        uint256 _quote = _priceInCoin0(quoteIndex);
        if (_base == 0 || _quote == 0) revert InvalidPrice();
        return (_base * 1e18) / _quote;
    }

    /// @dev 18-decimal result: emaRatio (1e18) * quotePrice / 10^quoteFeedDecimals.
    function _derive(int256 quotePrice_) private view returns (int256 _result) {
        if (quotePrice_ <= 0) revert InvalidPrice();
        _result = int256((emaRatio() * uint256(quotePrice_)) / _quoteFeedUnit);
        if (_result <= 0) revert InvalidPrice();
    }

    /// @dev EMA price of coin `k` in coin 0 (coin 0 itself is 1).
    function _priceInCoin0(uint256 k_) private view returns (uint256) {
        return k_ == 0 ? 1e18 : pool.price_oracle(k_ - 1);
    }
}
