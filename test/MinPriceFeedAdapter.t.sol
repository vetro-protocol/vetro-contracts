// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MinPriceFeedAdapter} from "src/MinPriceFeedAdapter.sol";
import {MockChainlinkOracle} from "test/mocks/MockChainlinkOracle.sol";

contract MinPriceFeedAdapterTest is Test {
    MockChainlinkOracle feedA;
    MockChainlinkOracle feedB;
    MinPriceFeedAdapter adapter;

    function setUp() public {
        // feedA: 18-decimal exchange-rate feed at par; feedB: 18-decimal market price below par
        feedA = new MockChainlinkOracle(1e18);
        feedA.setDecimals(18);
        feedB = new MockChainlinkOracle(0.999112e18);
        feedB.setDecimals(18);
        adapter = new MinPriceFeedAdapter(feedA, feedB, 18);
    }

    // ── constructor ──────────────────────────────────────────────────────────

    function test_constructor_storesFeeds() public view {
        assertEq(address(adapter.feedA()), address(feedA));
        assertEq(address(adapter.feedB()), address(feedB));
    }

    function test_constructor_revertIfFeedIsZero() public {
        vm.expectRevert(MinPriceFeedAdapter.ZeroAddress.selector);
        new MinPriceFeedAdapter(MockChainlinkOracle(address(0)), feedB, 18);

        vm.expectRevert(MinPriceFeedAdapter.ZeroAddress.selector);
        new MinPriceFeedAdapter(feedA, MockChainlinkOracle(address(0)), 18);
    }

    function test_constructor_revertIfOutputDecimalsTooLow() public {
        vm.expectRevert(MinPriceFeedAdapter.OutputDecimalsTooLow.selector);
        new MinPriceFeedAdapter(feedA, feedB, 7);
    }

    // ── metadata ─────────────────────────────────────────────────────────────

    function test_decimals() public view {
        assertEq(adapter.decimals(), 18);
    }

    function test_description() public view {
        assertEq(adapter.description(), string.concat("min(", feedA.description(), ", ", feedB.description(), ")"));
    }

    function test_version() public view {
        assertEq(adapter.version(), 1);
    }

    // ── latestRoundData ──────────────────────────────────────────────────────

    function test_latestRoundData_returnsLowerOfB() public view {
        (uint80 _roundId, int256 _answer,,, uint80 _answeredInRound) = adapter.latestRoundData();
        assertEq(_answer, 0.999112e18);
        assertEq(_roundId, 1);
        assertEq(_answeredInRound, 1);
    }

    function test_latestRoundData_returnsLowerOfA() public {
        feedA.updatePrice(0.98e18);
        (, int256 _answer,,,) = adapter.latestRoundData();
        assertEq(_answer, 0.98e18);
    }

    function test_latestRoundData_raisingOneSourceHasNoEffect() public {
        feedB.updatePrice(1.05e18);
        (, int256 _answer,,,) = adapter.latestRoundData();
        assertEq(_answer, 1e18);
    }

    function test_latestRoundData_normalisesMixedDecimals() public {
        // cbBTC case: 8-decimal derived feed vs 18-decimal Curve EMA leg, 8-decimal output
        MockChainlinkOracle _derived = new MockChainlinkOracle(1.00225087e8);
        MockChainlinkOracle _curve = new MockChainlinkOracle(0.999791e18);
        _curve.setDecimals(18);
        MinPriceFeedAdapter _adapter = new MinPriceFeedAdapter(_derived, _curve, 8);
        (, int256 _answer,,,) = _adapter.latestRoundData();
        assertEq(_answer, 0.999791e8);

        MinPriceFeedAdapter _adapter18 = new MinPriceFeedAdapter(_derived, _curve, 18);
        (, _answer,,,) = _adapter18.latestRoundData();
        assertEq(_answer, 0.999791e18);
    }

    function test_latestRoundData_updatedAtIsOlderFeed() public {
        vm.warp(1_000_000);
        feedA.setUpdatedAt(900_000);
        feedB.setUpdatedAt(999_000);
        (,, uint256 _startedAt, uint256 _updatedAt,) = adapter.latestRoundData();
        assertEq(_updatedAt, 900_000);
        assertEq(_startedAt, 900_000);
        assertEq(adapter.latestTimestamp(), 900_000);

        // Staleness follows the older feed even when the fresher one is the lower answer
        feedA.setUpdatedAt(999_000);
        feedB.setUpdatedAt(900_000);
        (,,, _updatedAt,) = adapter.latestRoundData();
        assertEq(_updatedAt, 900_000);
    }

    function test_latestRoundData_revertIfEitherPriceNotPositive() public {
        feedA.updatePrice(0);
        vm.expectRevert(MinPriceFeedAdapter.InvalidPrice.selector);
        adapter.latestRoundData();

        feedA.updatePrice(1e18);
        feedB.updatePrice(-1);
        vm.expectRevert(MinPriceFeedAdapter.InvalidPrice.selector);
        adapter.latestRoundData();
    }

    function test_latestRoundData_revertIfScaledPriceRoundsToZero() public {
        MockChainlinkOracle _feed8 = new MockChainlinkOracle(1e8);
        MinPriceFeedAdapter _adapter8 = new MinPriceFeedAdapter(_feed8, feedB, 8);
        feedB.updatePrice(1); // 1e-18 rounds to 0 at 8 decimals
        vm.expectRevert(MinPriceFeedAdapter.InvalidPrice.selector);
        _adapter8.latestRoundData();
    }

    function testFuzz_latestRoundData_isMin(int256 priceA_, int256 priceB_) public {
        priceA_ = bound(priceA_, 1, 1e30);
        priceB_ = bound(priceB_, 1, 1e30);
        feedA.updatePrice(priceA_);
        feedB.updatePrice(priceB_);
        (, int256 _answer,,,) = adapter.latestRoundData();
        assertEq(_answer, priceA_ < priceB_ ? priceA_ : priceB_);
    }

    // ── AggregatorInterface ──────────────────────────────────────────────────

    function test_latestAnswer_matchesLatestRoundData() public view {
        (, int256 _answer,,,) = adapter.latestRoundData();
        assertEq(adapter.latestAnswer(), _answer);
    }

    function test_latestRound() public view {
        assertEq(adapter.latestRound(), 1);
    }

    function test_historicalRounds_revert() public {
        vm.expectRevert(MinPriceFeedAdapter.HistoricalRoundsNotSupported.selector);
        adapter.getRoundData(1);
        vm.expectRevert(MinPriceFeedAdapter.HistoricalRoundsNotSupported.selector);
        adapter.getAnswer(1);
        vm.expectRevert(MinPriceFeedAdapter.HistoricalRoundsNotSupported.selector);
        adapter.getTimestamp(1);
    }
}
