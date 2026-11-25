// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MinPriceFeedAdapter} from "src/MinPriceFeedAdapter.sol";
import {MockChainlinkOracle} from "test/mocks/MockChainlinkOracle.sol";

contract MinPriceFeedAdapterTest is Test {
    uint256 constant NO_BOUND = 10_000;
    uint256 constant CBBTC_MAX_DEVIATION = 50;

    MockChainlinkOracle feedA;
    MockChainlinkOracle feedB;
    MinPriceFeedAdapter adapter;

    function setUp() public {
        // feedA: 18-decimal exchange-rate feed at par; feedB: 18-decimal market price below par
        feedA = new MockChainlinkOracle(1e18);
        feedA.setDecimals(18);
        feedB = new MockChainlinkOracle(0.999112e18);
        feedB.setDecimals(18);
        adapter = new MinPriceFeedAdapter(feedA, feedB, 18, NO_BOUND);
    }

    // ── constructor ──────────────────────────────────────────────────────────

    function test_constructor_storesFeeds() public view {
        assertEq(address(adapter.feedA()), address(feedA));
        assertEq(address(adapter.feedB()), address(feedB));
    }

    function test_constructor_revertIfFeedIsZero() public {
        vm.expectRevert(MinPriceFeedAdapter.ZeroAddress.selector);
        new MinPriceFeedAdapter(MockChainlinkOracle(address(0)), feedB, 18, NO_BOUND);

        vm.expectRevert(MinPriceFeedAdapter.ZeroAddress.selector);
        new MinPriceFeedAdapter(feedA, MockChainlinkOracle(address(0)), 18, NO_BOUND);
    }

    function test_constructor_revertIfOutputDecimalsTooLow() public {
        vm.expectRevert(MinPriceFeedAdapter.OutputDecimalsTooLow.selector);
        new MinPriceFeedAdapter(feedA, feedB, 7, NO_BOUND);
    }

    function test_constructor_storesMaxDeviation() public {
        assertEq(adapter.maxDeviation(), NO_BOUND);
        assertEq(new MinPriceFeedAdapter(feedA, feedB, 18, 0).maxDeviation(), 0);
    }

    function test_constructor_revertIfMaxDeviationTooHigh() public {
        vm.expectRevert(MinPriceFeedAdapter.MaxDeviationTooHigh.selector);
        new MinPriceFeedAdapter(feedA, feedB, 18, NO_BOUND + 1);
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
        MinPriceFeedAdapter _adapter = new MinPriceFeedAdapter(_derived, _curve, 8, CBBTC_MAX_DEVIATION);
        (, int256 _answer,,,) = _adapter.latestRoundData();
        assertEq(_answer, 0.999791e8);

        MinPriceFeedAdapter _adapter18 = new MinPriceFeedAdapter(_derived, _curve, 18, CBBTC_MAX_DEVIATION);
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
        MinPriceFeedAdapter _adapter8 = new MinPriceFeedAdapter(_feed8, feedB, 8, NO_BOUND);
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

    // ── maxDeviation ──────────────────────────────────────────────────────────

    function test_maxDeviation_feedBInsideBound() public {
        MinPriceFeedAdapter _adapter = new MinPriceFeedAdapter(feedA, feedB, 18, CBBTC_MAX_DEVIATION);
        feedB.updatePrice(0.996e18);
        (, int256 _answer,,,) = _adapter.latestRoundData();
        assertEq(_answer, 0.996e18);
    }

    function test_maxDeviation_feedBAtBound() public {
        MinPriceFeedAdapter _adapter = new MinPriceFeedAdapter(feedA, feedB, 18, CBBTC_MAX_DEVIATION);
        feedA.updatePrice(1.01e18);
        feedB.updatePrice(1.00495e18);
        (, int256 _answer,,,) = _adapter.latestRoundData();
        assertEq(_answer, 1.00495e18);
    }

    function test_maxDeviation_revertIfFeedBBelowBound() public {
        MinPriceFeedAdapter _adapter = new MinPriceFeedAdapter(feedA, feedB, 18, CBBTC_MAX_DEVIATION);
        feedA.updatePrice(1.01e18);
        feedB.updatePrice(1.00494e18);
        vm.expectRevert(MinPriceFeedAdapter.MaxDeviationExceeded.selector);
        _adapter.latestRoundData();
        vm.expectRevert(MinPriceFeedAdapter.MaxDeviationExceeded.selector);
        _adapter.latestAnswer();
    }

    function test_maxDeviation_feedAAtBound() public {
        MinPriceFeedAdapter _adapter = new MinPriceFeedAdapter(feedA, feedB, 18, CBBTC_MAX_DEVIATION);
        feedA.updatePrice(1.00495e18);
        feedB.updatePrice(1.01e18);
        (, int256 _answer,,,) = _adapter.latestRoundData();
        assertEq(_answer, 1.00495e18);
    }

    function test_maxDeviation_revertIfFeedABelowBound() public {
        MinPriceFeedAdapter _adapter = new MinPriceFeedAdapter(feedA, feedB, 18, CBBTC_MAX_DEVIATION);
        feedA.updatePrice(1.00494e18);
        feedB.updatePrice(1.01e18);
        vm.expectRevert(MinPriceFeedAdapter.MaxDeviationExceeded.selector);
        _adapter.latestRoundData();
        vm.expectRevert(MinPriceFeedAdapter.MaxDeviationExceeded.selector);
        _adapter.latestAnswer();
    }

    function test_maxDeviation_zeroRevertsUnlessFeedsAreEqual() public {
        MinPriceFeedAdapter _adapter = new MinPriceFeedAdapter(feedA, feedB, 18, 0);
        vm.expectRevert(MinPriceFeedAdapter.MaxDeviationExceeded.selector);
        _adapter.latestRoundData();

        feedB.updatePrice(1.000001e18);
        vm.expectRevert(MinPriceFeedAdapter.MaxDeviationExceeded.selector);
        _adapter.latestRoundData();

        feedB.updatePrice(1e18);
        (, int256 _answer,,,) = _adapter.latestRoundData();
        assertEq(_answer, 1e18);
    }

    function test_maxDeviation_normalisesMixedDecimals() public {
        MockChainlinkOracle _derived = new MockChainlinkOracle(1.01e8);
        MockChainlinkOracle _curve = new MockChainlinkOracle(1.00495e18);
        _curve.setDecimals(18);
        MinPriceFeedAdapter _adapter = new MinPriceFeedAdapter(_derived, _curve, 18, CBBTC_MAX_DEVIATION);
        (, int256 _answer,,,) = _adapter.latestRoundData();
        assertEq(_answer, 1.00495e18);

        _curve.updatePrice(1.00494e18);
        vm.expectRevert(MinPriceFeedAdapter.MaxDeviationExceeded.selector);
        _adapter.latestRoundData();
    }

    function testFuzz_maxDeviation_boundsDifference(int256 priceA_, int256 priceB_, uint256 maxDeviation_) public {
        priceA_ = bound(priceA_, 1, 1e30);
        priceB_ = bound(priceB_, 1, 1e30);
        maxDeviation_ = bound(maxDeviation_, 0, NO_BOUND);
        MinPriceFeedAdapter _adapter = new MinPriceFeedAdapter(feedA, feedB, 18, maxDeviation_);
        feedA.updatePrice(priceA_);
        feedB.updatePrice(priceB_);

        (int256 _high, int256 _low) = priceA_ > priceB_ ? (priceA_, priceB_) : (priceB_, priceA_);
        if ((_high - _low) * int256(NO_BOUND) > _high * int256(maxDeviation_)) {
            vm.expectRevert(MinPriceFeedAdapter.MaxDeviationExceeded.selector);
            _adapter.latestRoundData();
        } else {
            (, int256 _answer,,,) = _adapter.latestRoundData();
            assertEq(_answer, _low);
        }
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
