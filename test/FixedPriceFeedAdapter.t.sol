// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {FixedPriceFeedAdapter} from "src/FixedPriceFeedAdapter.sol";

contract FixedPriceFeedAdapterTest is Test {
    int256 constant PRICE = 1e8; // 1.0 at 8 decimals
    uint8 constant DECIMALS = 8;
    string constant DESCRIPTION = "WBTC / BTC";

    FixedPriceFeedAdapter adapter;

    function setUp() public {
        adapter = new FixedPriceFeedAdapter(PRICE, DECIMALS, DESCRIPTION);
    }

    // ── constructor ──────────────────────────────────────────────────────────

    function test_constructor_storesValues() public view {
        assertEq(adapter.decimals(), DECIMALS);
        assertEq(adapter.description(), DESCRIPTION);
    }

    function test_constructor_revertIfPriceIsZero() public {
        vm.expectRevert(FixedPriceFeedAdapter.InvalidPrice.selector);
        new FixedPriceFeedAdapter(0, DECIMALS, DESCRIPTION);
    }

    function test_constructor_revertIfPriceIsNegative() public {
        vm.expectRevert(FixedPriceFeedAdapter.InvalidPrice.selector);
        new FixedPriceFeedAdapter(-1, DECIMALS, DESCRIPTION);
    }

    // ── metadata ─────────────────────────────────────────────────────────────

    function test_decimals() public view {
        assertEq(adapter.decimals(), 8);
    }

    function test_description() public view {
        assertEq(adapter.description(), DESCRIPTION);
    }

    function test_version() public view {
        assertEq(adapter.version(), 1);
    }

    // ── latestRoundData ──────────────────────────────────────────────────────

    function test_latestRoundData_returnsFixedPrice() public view {
        (, int256 answer,,,) = adapter.latestRoundData();
        assertEq(answer, PRICE);
    }

    function test_latestRoundData_updatedAtIsCurrentBlock() public view {
        (,,, uint256 updatedAt,) = adapter.latestRoundData();
        assertEq(updatedAt, block.timestamp);
    }

    function test_latestRoundData_roundFieldsAreOne() public view {
        (uint80 roundId,,,, uint80 answeredInRound) = adapter.latestRoundData();
        assertEq(roundId, 1);
        assertEq(answeredInRound, 1);
    }

    function test_latestRoundData_updatedAtAdvancesWithTime() public {
        uint256 later = block.timestamp + 1 days;
        vm.warp(later);
        (,,, uint256 updatedAt,) = adapter.latestRoundData();
        assertEq(updatedAt, later);
    }

    // ── getRoundData ─────────────────────────────────────────────────────────

    function test_getRoundData_returnsFixedPriceForAnyRound() public view {
        (uint80 roundId, int256 answer,,, uint80 answeredInRound) = adapter.getRoundData(42);
        assertEq(roundId, 42);
        assertEq(answer, PRICE);
        assertEq(answeredInRound, 42);
    }

    // ── V2 interface ─────────────────────────────────────────────────────────

    function test_latestAnswer() public view {
        assertEq(adapter.latestAnswer(), PRICE);
    }

    function test_latestTimestamp_isCurrentBlock() public view {
        assertEq(adapter.latestTimestamp(), block.timestamp);
    }

    function test_latestRound_returnsOne() public view {
        assertEq(adapter.latestRound(), 1);
    }

    function test_getAnswer_returnsFixedPriceForAnyId() public view {
        assertEq(adapter.getAnswer(999), PRICE);
    }

    function test_getTimestamp_isCurrentBlock() public view {
        assertEq(adapter.getTimestamp(999), block.timestamp);
    }

    // ── fuzz ─────────────────────────────────────────────────────────────────

    function testFuzz_latestRoundData_alwaysReturnsConfiguredPrice(int256 price_, uint8 decimals_) public {
        vm.assume(price_ > 0);
        FixedPriceFeedAdapter fuzz = new FixedPriceFeedAdapter(price_, decimals_, "");
        (, int256 answer,,,) = fuzz.latestRoundData();
        assertEq(answer, price_);
        assertEq(fuzz.decimals(), decimals_);
    }
}
