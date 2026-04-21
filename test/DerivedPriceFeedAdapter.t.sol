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
        adapter = new DerivedPriceFeedAdapter(baseFeed, quoteFeed, 8);
    }

    // ── constructor ──────────────────────────────────────────────────────────

    function test_constructor_storesFeeds() public view {
        assertEq(address(adapter.baseFeed()), address(baseFeed));
        assertEq(address(adapter.quoteFeed()), address(quoteFeed));
    }

    function test_constructor_revertIfBaseFeedIsZero() public {
        vm.expectRevert(DerivedPriceFeedAdapter.ZeroAddress.selector);
        new DerivedPriceFeedAdapter(MockChainlinkOracle(address(0)), quoteFeed, 8);
    }

    function test_constructor_revertIfQuoteFeedIsZero() public {
        vm.expectRevert(DerivedPriceFeedAdapter.ZeroAddress.selector);
        new DerivedPriceFeedAdapter(baseFeed, MockChainlinkOracle(address(0)), 8);
    }

    function test_constructor_revertIfOutputDecimalsTooLow() public {
        vm.expectRevert(DerivedPriceFeedAdapter.OutputDecimalsTooLow.selector);
        new DerivedPriceFeedAdapter(baseFeed, quoteFeed, 7);
    }

    function test_constructor_allowsDifferentFeedDecimals() public {
        MockChainlinkOracle feed18 = new MockChainlinkOracle(75_298.57e18);
        feed18.setDecimals(18);
        // baseFeed 8 decimals, quoteFeed 18 decimals — should not revert
        new DerivedPriceFeedAdapter(baseFeed, feed18, 8);
    }

    // ── metadata ─────────────────────────────────────────────────────────────

    function test_decimals() public view {
        assertEq(adapter.decimals(), 8);
    }

    function test_decimals_deployer_can_set_18() public {
        DerivedPriceFeedAdapter adapter18 = new DerivedPriceFeedAdapter(baseFeed, quoteFeed, 18);
        assertEq(adapter18.decimals(), 18);
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

    function test_latestRoundData_roundFieldsAreOne() public view {
        (uint80 roundId,,,, uint80 answeredInRound) = adapter.latestRoundData();
        assertEq(roundId, 1);
        assertEq(answeredInRound, 1);
    }

    function test_latestRoundData_startedAtEqualsUpdatedAt() public view {
        (,, uint256 startedAt, uint256 updatedAt,) = adapter.latestRoundData();
        assertEq(startedAt, updatedAt);
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

    function test_latestRoundData_differentFeedDecimals() public {
        // baseFeed: 18 decimals (e.g. hemiBTC/USD)
        // quoteFeed: 8 decimals (BTC/USD standard)
        // output: 8 decimals
        // result = (basePrice * 10^(8+8)) / (quotePrice * 10^18)
        //        = basePrice / (quotePrice * 100) ... simplified
        int256 basePrice18 = 75_298.57e18;
        int256 quotePrice8 = 76_351.94e8;

        MockChainlinkOracle feed18 = new MockChainlinkOracle(basePrice18);
        feed18.setDecimals(18);
        DerivedPriceFeedAdapter mixedAdapter = new DerivedPriceFeedAdapter(feed18, quoteFeed, 8);

        quoteFeed.updatePrice(quotePrice8);
        (, int256 answer,,,) = mixedAdapter.latestRoundData();

        int256 expected = (basePrice18 * int256(10 ** (8 + 8))) / (quotePrice8 * int256(10 ** 18));
        assertEq(answer, expected);
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

    function test_latestRound_returnsOne() public view {
        assertEq(adapter.latestRound(), 1);
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
