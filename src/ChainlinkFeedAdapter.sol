// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {
    AggregatorInterface,
    AggregatorV3Interface,
    AggregatorV2V3Interface
} from "@chainlink/contracts/interfaces/feeds/AggregatorV2V3Interface.sol";

/// @title ChainlinkFeedAdapter
/// @notice Chainlink AggregatorV3-compatible oracle adapter that delegates to an underlying feed.
///         Morpho markets fix their oracle address at creation time; this adapter lets the owner
///         swap the underlying price feed without changing the address seen by the market.
contract ChainlinkFeedAdapter is Ownable2Step, AggregatorV2V3Interface {
    uint96 constant NEW_FEED_COOLDOWN = 7 days;

    event FeedUpdateInitialized(address indexed oldFeed, address indexed newFeed, uint96 pendingUntil);
    event FeedUpdated(address indexed oldFeed, address indexed newFeed);

    error AddressIsZero();
    error DecimalsDoNotMatch();
    error NoPendingFeed();
    error CooldownNotExpired();

    AggregatorV2V3Interface public feed;
    AggregatorV2V3Interface public pendingFeed;
    uint96 public pendingUntil;

    constructor(AggregatorV2V3Interface feed_, address owner_) Ownable(owner_) {
        if (address(feed_) == address(0)) revert AddressIsZero();
        feed = feed_;
        emit FeedUpdated(address(0), address(feed_));
    }

    /// @notice Initialize the update of the underlying feed
    function initializeFeedUpdate(AggregatorV2V3Interface newFeed_) external onlyOwner {
        if (address(newFeed_) == address(0)) revert AddressIsZero();
        AggregatorV2V3Interface _currentFeed = feed;
        if (newFeed_.decimals() != _currentFeed.decimals()) revert DecimalsDoNotMatch();
        pendingFeed = AggregatorV2V3Interface(newFeed_);
        pendingUntil = uint96(block.timestamp + NEW_FEED_COOLDOWN);
        emit FeedUpdateInitialized(address(_currentFeed), address(newFeed_), pendingUntil);
    }

    /// @notice Replace the underlying feed
    function updateFeed() external onlyOwner {
        if (address(pendingFeed) == address(0)) revert NoPendingFeed();
        if (block.timestamp < pendingUntil) revert CooldownNotExpired();
        AggregatorV2V3Interface _pendingFeed = pendingFeed;
        emit FeedUpdated(address(feed), address(_pendingFeed));
        delete pendingUntil;
        delete pendingFeed;
        feed = _pendingFeed;
    }

    /// @inheritdoc AggregatorV3Interface
    function decimals() external view returns (uint8) {
        return feed.decimals();
    }

    /// @inheritdoc AggregatorV3Interface
    function description() external view returns (string memory) {
        return feed.description();
    }

    /// @inheritdoc AggregatorV3Interface
    function version() external view returns (uint256) {
        return feed.version();
    }

    /// @inheritdoc AggregatorV3Interface
    function getRoundData(uint80 roundId_)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return feed.getRoundData(roundId_);
    }

    /// @inheritdoc AggregatorV3Interface
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return feed.latestRoundData();
    }

    /// @inheritdoc AggregatorInterface
    function latestAnswer() external view returns (int256) {
        return feed.latestAnswer();
    }

    /// @inheritdoc AggregatorInterface
    function latestTimestamp() external view returns (uint256) {
        return feed.latestTimestamp();
    }

    /// @inheritdoc AggregatorInterface
    function latestRound() external view returns (uint256) {
        return feed.latestRound();
    }

    /// @inheritdoc AggregatorInterface
    function getAnswer(uint256 roundId_) external view returns (int256) {
        return feed.getAnswer(roundId_);
    }

    /// @inheritdoc AggregatorInterface
    function getTimestamp(uint256 roundId_) external view returns (uint256) {
        return feed.getTimestamp(roundId_);
    }
}
