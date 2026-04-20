// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AggregatorV2V3Interface} from "@chainlink/contracts/interfaces/feeds/AggregatorV2V3Interface.sol";
import {DerivedPriceFeedAdapter} from "src/DerivedPriceFeedAdapter.sol";
import {MockChainlinkOracle} from "test/mocks/MockChainlinkOracle.sol";

contract DerivedPriceFeedAdapterTest is Test {
    // Realistic BTC-range prices at 8 decimals (e.g. cbBTC/USD and BTC/USD)
    int256 constant BASE_USD_PRICE = 75_298.57e8;
    int256 constant QUOTE_USD_PRICE = 76_351.94e8;

    MockChainlinkOracle baseFeed;
    MockChainlinkOracle quoteFeed;
    DerivedPriceFeedAdapter adapter;

    function setUp() public {
        baseFeed = new MockChainlinkOracle(BASE_USD_PRICE);
        quoteFeed = new MockChainlinkOracle(QUOTE_USD_PRICE);
        adapter = new DerivedPriceFeedAdapter(baseFeed, quoteFeed);
    }

    // ── constructor ──────────────────────────────────────────────────────────

    function test_constructor_storesFeeds() public view {
        assertEq(address(adapter.baseFeed()), address(baseFeed));
        assertEq(address(adapter.quoteFeed()), address(quoteFeed));
    }

    function test_constructor_revertIfBaseFeedIsZero() public {
        vm.expectRevert(DerivedPriceFeedAdapter.ZeroAddress.selector);
        new DerivedPriceFeedAdapter(MockChainlinkOracle(address(0)), quoteFeed);
    }

    function test_constructor_revertIfQuoteFeedIsZero() public {
        vm.expectRevert(DerivedPriceFeedAdapter.ZeroAddress.selector);
        new DerivedPriceFeedAdapter(baseFeed, MockChainlinkOracle(address(0)));
    }

    function test_constructor_revertIfDecimalsMismatch() public {
        MockDifferentDecimals wrongDecimals = new MockDifferentDecimals(18);
        vm.expectRevert(DerivedPriceFeedAdapter.FeedDecimalsMismatch.selector);
        new DerivedPriceFeedAdapter(baseFeed, wrongDecimals);
    }

    // ── metadata ─────────────────────────────────────────────────────────────

    function test_decimals() public view {
        assertEq(adapter.decimals(), baseFeed.decimals());
        assertEq(adapter.decimals(), 8);
    }

    function test_description() public view {
        string memory expected = string.concat(baseFeed.description(), " / ", quoteFeed.description(), " derived");
        assertEq(adapter.description(), expected);
    }

    function test_version() public view {
        assertEq(adapter.version(), 1);
    }

    // ── latestRoundData ──────────────────────────────────────────────────────

    function test_latestRoundData_derivedPrice() public view {
        (, int256 answer,,,) = adapter.latestRoundData();
        int256 expected = (BASE_USD_PRICE * 1e8) / QUOTE_USD_PRICE;
        assertEq(answer, expected);
    }

    function test_latestRoundData_roundFieldsAreZero() public view {
        (uint80 roundId,,,, uint80 answeredInRound) = adapter.latestRoundData();
        assertEq(roundId, 0);
        assertEq(answeredInRound, 0);
    }

    function test_latestRoundData_exactParity() public {
        baseFeed.updatePrice(QUOTE_USD_PRICE);
        (, int256 answer,,,) = adapter.latestRoundData();
        assertEq(answer, 1e8); // exactly 1.0 in 8-decimal representation
    }

    function test_latestRoundData_usesMinUpdatedAt() public {
        // baseFeed was created earlier; quoteFeed updated later
        uint256 baseTimestamp = block.timestamp;
        vm.warp(block.timestamp + 1 hours);
        quoteFeed.updatePrice(QUOTE_USD_PRICE);

        (,,, uint256 updatedAt,) = adapter.latestRoundData();
        assertEq(updatedAt, baseTimestamp); // min of the two
    }

    function test_latestRoundData_revertIfBasePriceZero() public {
        baseFeed.updatePrice(0);
        vm.expectRevert(DerivedPriceFeedAdapter.InvalidPrice.selector);
        adapter.latestRoundData();
    }

    function test_latestRoundData_revertIfQuotePriceZero() public {
        quoteFeed.updatePrice(0);
        vm.expectRevert(DerivedPriceFeedAdapter.InvalidPrice.selector);
        adapter.latestRoundData();
    }

    function test_latestRoundData_revertIfBasePriceNegative() public {
        baseFeed.updatePrice(-1);
        vm.expectRevert(DerivedPriceFeedAdapter.InvalidPrice.selector);
        adapter.latestRoundData();
    }

    function test_latestRoundData_revertIfQuotePriceNegative() public {
        quoteFeed.updatePrice(-1);
        vm.expectRevert(DerivedPriceFeedAdapter.InvalidPrice.selector);
        adapter.latestRoundData();
    }

    // ── getRoundData ─────────────────────────────────────────────────────────

    function test_getRoundData_reverts() public {
        vm.expectRevert(DerivedPriceFeedAdapter.HistoricalRoundsNotSupported.selector);
        adapter.getRoundData(1);
    }

    // ── V2 interface ─────────────────────────────────────────────────────────

    function test_latestAnswer() public view {
        int256 expected = (BASE_USD_PRICE * 1e8) / QUOTE_USD_PRICE;
        assertEq(adapter.latestAnswer(), expected);
    }

    function test_latestTimestamp_usesMin() public {
        uint256 baseTimestamp = block.timestamp;
        vm.warp(block.timestamp + 30 minutes);
        quoteFeed.updatePrice(QUOTE_USD_PRICE);

        assertEq(adapter.latestTimestamp(), baseTimestamp);
    }

    function test_latestRound_returnsZero() public view {
        assertEq(adapter.latestRound(), 0);
    }

    function test_getAnswer_reverts() public {
        vm.expectRevert(DerivedPriceFeedAdapter.HistoricalRoundsNotSupported.selector);
        adapter.getAnswer(1);
    }

    function test_getTimestamp_reverts() public {
        vm.expectRevert(DerivedPriceFeedAdapter.HistoricalRoundsNotSupported.selector);
        adapter.getTimestamp(1);
    }
}

/// @dev Minimal AggregatorV2V3Interface mock with configurable decimals, for constructor revert testing.
contract MockDifferentDecimals is AggregatorV2V3Interface {
    uint8 private _dec;

    constructor(uint8 dec_) {
        _dec = dec_;
    }

    function decimals() external view returns (uint8) {
        return _dec;
    }

    function description() external pure returns (string memory) {
        return "";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        return (0, 1e18, 0, 0, 0);
    }

    function getRoundData(uint80 r) external pure returns (uint80, int256, uint256, uint256, uint80) {
        return (r, 1e18, 0, 0, r);
    }

    function latestAnswer() external pure returns (int256) {
        return 1e18;
    }

    function latestTimestamp() external pure returns (uint256) {
        return 0;
    }

    function latestRound() external pure returns (uint256) {
        return 0;
    }

    function getAnswer(uint256) external pure returns (int256) {
        return 1e18;
    }

    function getTimestamp(uint256) external pure returns (uint256) {
        return 0;
    }
}
