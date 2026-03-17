// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ChainlinkFeedAdapter} from "src/ChainlinkFeedAdapter.sol";
import {MockChainlinkOracle} from "test/mocks/MockChainlinkOracle.sol";

contract ChainlinkFeedAdapterTest is Test {
    ChainlinkFeedAdapter oracle;
    MockChainlinkOracle initialFeed;
    MockChainlinkOracle newFeed;

    address owner = makeAddr("owner");
    address stranger = makeAddr("stranger");

    uint96 constant NEW_FEED_COOLDOWN = 7 days;

    function setUp() public {
        initialFeed = new MockChainlinkOracle(60_000e8);
        newFeed = new MockChainlinkOracle(61_000e8);

        oracle = new ChainlinkFeedAdapter(initialFeed, owner);
    }

    function test_underlyingFeedData() public view {
        assertEq(oracle.decimals(), initialFeed.decimals());
        assertEq(oracle.description(), initialFeed.description());
        assertEq(oracle.version(), initialFeed.version());

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            oracle.latestRoundData();
        (uint80 eRoundId, int256 eAnswer, uint256 eStartedAt, uint256 eUpdatedAt, uint80 eAnsweredInRound) =
            initialFeed.latestRoundData();
        assertEq(roundId, eRoundId);
        assertEq(answer, eAnswer);
        assertEq(startedAt, eStartedAt);
        assertEq(updatedAt, eUpdatedAt);
        assertEq(answeredInRound, eAnsweredInRound);

        (roundId, answer, startedAt, updatedAt, answeredInRound) = oracle.getRoundData(1);
        (eRoundId, eAnswer, eStartedAt, eUpdatedAt, eAnsweredInRound) = initialFeed.getRoundData(1);
        assertEq(roundId, eRoundId);
        assertEq(answer, eAnswer);
        assertEq(startedAt, eStartedAt);
        assertEq(updatedAt, eUpdatedAt);
        assertEq(answeredInRound, eAnsweredInRound);

        assertEq(oracle.latestAnswer(), initialFeed.latestAnswer());
        assertEq(oracle.latestTimestamp(), initialFeed.latestTimestamp());
        assertEq(oracle.latestRound(), initialFeed.latestRound());
        assertEq(oracle.getAnswer(1), initialFeed.getAnswer(1));
        assertEq(oracle.getTimestamp(1), initialFeed.getTimestamp(1));
    }

    function test_initializeFeedUpdate() public {
        uint96 expectedPendingUntil = uint96(block.timestamp + NEW_FEED_COOLDOWN);

        vm.expectEmit(true, true, false, true, address(oracle));
        emit ChainlinkFeedAdapter.FeedUpdateInitialized(address(initialFeed), address(newFeed), expectedPendingUntil);

        vm.prank(owner);
        oracle.initializeFeedUpdate(newFeed);

        assertEq(address(oracle.pendingFeed()), address(newFeed));
        assertEq(oracle.pendingUntil(), expectedPendingUntil);
        assertEq(address(oracle.feed()), address(initialFeed), "current feed should not change yet");
    }

    function test_initializeFeedUpdate_revertIfNewFeedIsNull() public {
        vm.prank(owner);
        vm.expectRevert(ChainlinkFeedAdapter.AddressIsZero.selector);
        oracle.initializeFeedUpdate(MockChainlinkOracle(address(0)));
    }

    function test_initializeFeedUpdate_whenReinitializing() public {
        MockChainlinkOracle anotherFeed = new MockChainlinkOracle(62_000e8);

        vm.startPrank(owner);
        oracle.initializeFeedUpdate(newFeed);

        uint96 newPendingUntil = uint96(block.timestamp + NEW_FEED_COOLDOWN);

        vm.expectEmit(true, true, false, true, address(oracle));
        emit ChainlinkFeedAdapter.FeedUpdateInitialized(address(initialFeed), address(anotherFeed), newPendingUntil);

        oracle.initializeFeedUpdate(anotherFeed);
        vm.stopPrank();

        assertEq(address(oracle.pendingFeed()), address(anotherFeed));
        assertEq(oracle.pendingUntil(), newPendingUntil);
    }

    function test_initializeFeedUpdate_revertIfNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        oracle.initializeFeedUpdate(newFeed);
    }

    function test_updateFeed() public {
        vm.prank(owner);
        oracle.initializeFeedUpdate(newFeed);

        vm.warp(block.timestamp + NEW_FEED_COOLDOWN);

        vm.expectEmit(true, true, false, false, address(oracle));
        emit ChainlinkFeedAdapter.FeedUpdated(address(initialFeed), address(newFeed));

        vm.prank(owner);
        oracle.updateFeed();

        assertEq(address(oracle.feed()), address(newFeed));
        assertEq(address(oracle.pendingFeed()), address(0));
        assertEq(oracle.pendingUntil(), 0);
    }

    function test_updateFeed_revertIfNotOwner() public {
        vm.prank(owner);
        oracle.initializeFeedUpdate(newFeed);

        vm.warp(block.timestamp + NEW_FEED_COOLDOWN);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        oracle.updateFeed();
    }

    function test_updateFeed_revertIfCooldownDidNotPass() public {
        vm.prank(owner);
        oracle.initializeFeedUpdate(newFeed);

        vm.warp(block.timestamp + NEW_FEED_COOLDOWN - 1);

        vm.prank(owner);
        vm.expectRevert(ChainlinkFeedAdapter.CooldownNotExpired.selector);
        oracle.updateFeed();
    }

    function test_updateFeed_revertIfThereIsNoPendingFeed() public {
        vm.prank(owner);
        vm.expectRevert(ChainlinkFeedAdapter.NoPendingFeed.selector);
        oracle.updateFeed();
    }
}
