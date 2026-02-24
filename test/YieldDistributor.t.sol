// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {YieldDistributor} from "src/YieldDistributor.sol";
import {IYieldDistributor} from "src/interfaces/IYieldDistributor.sol";
import {StakingVault} from "src/StakingVault.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract YieldDistributorTest is Test {
    YieldDistributor yieldDistributor;
    StakingVault vault;
    MockERC20 vusd;

    address owner = makeAddr("owner");
    address distributor = makeAddr("distributor");
    address alice = makeAddr("alice");

    uint256 constant UNIT = 1e6;
    uint256 constant PRECISION = 1e18;

    function setUp() public {
        vusd = new MockERC20();

        // Deploy StakingVault behind proxy
        StakingVault vaultImpl = new StakingVault();
        vault = StakingVault(
            address(
                new ERC1967Proxy(
                    address(vaultImpl),
                    abi.encodeCall(StakingVault.initialize, (address(vusd), "Staked VUSD", "sVUSD", owner))
                )
            )
        );

        // Deploy YieldDistributor behind proxy
        YieldDistributor yieldDistributorImpl = new YieldDistributor();
        yieldDistributor = YieldDistributor(
            address(
                new ERC1967Proxy(
                    address(yieldDistributorImpl),
                    abi.encodeCall(YieldDistributor.initialize, (address(vusd), address(vault), owner))
                )
            )
        );

        // Setup roles
        vm.startPrank(owner);
        vault.updateYieldDistributor(address(yieldDistributor));
        yieldDistributor.grantRole(yieldDistributor.DISTRIBUTOR_ROLE(), distributor);
        vm.stopPrank();

        // Give distributor some VUSD
        deal(address(vusd), distributor, 1000 * UNIT);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_initialize_success() public view {
        assertEq(address(yieldDistributor.asset()), address(vusd));
        assertEq(yieldDistributor.vault(), address(vault));
        assertEq(yieldDistributor.yieldDuration(), 7 days);
        assertTrue(yieldDistributor.hasRole(yieldDistributor.DEFAULT_ADMIN_ROLE(), owner));
    }

    function test_initialize_revert_zeroAsset() public {
        YieldDistributor newDistributorImpl = new YieldDistributor();
        vm.expectRevert(YieldDistributor.ZeroAddress.selector);
        new ERC1967Proxy(
            address(newDistributorImpl),
            abi.encodeCall(YieldDistributor.initialize, (address(0), address(vault), owner))
        );
    }

    function test_initialize_revert_zeroVault() public {
        YieldDistributor newDistributorImpl = new YieldDistributor();
        vm.expectRevert(YieldDistributor.ZeroAddress.selector);
        new ERC1967Proxy(
            address(newDistributorImpl), abi.encodeCall(YieldDistributor.initialize, (address(vusd), address(0), owner))
        );
    }

    function test_initialize_revert_zeroOwner() public {
        YieldDistributor newDistributorImpl = new YieldDistributor();
        vm.expectRevert(YieldDistributor.ZeroAddress.selector);
        new ERC1967Proxy(
            address(newDistributorImpl),
            abi.encodeCall(YieldDistributor.initialize, (address(vusd), address(vault), address(0)))
        );
    }

    function test_initialize_revert_alreadyInitialized() public {
        vm.expectRevert();
        yieldDistributor.initialize(address(vusd), address(vault), owner);
    }

    /*//////////////////////////////////////////////////////////////
                              DISTRIBUTE
    //////////////////////////////////////////////////////////////*/

    function test_distribute_success() public {
        uint256 amount = 100 * UNIT;

        vm.startPrank(distributor);
        vusd.approve(address(yieldDistributor), amount);
        yieldDistributor.distribute(amount);
        vm.stopPrank();

        assertEq(vusd.balanceOf(address(yieldDistributor)), amount);
        assertEq(yieldDistributor.periodFinish(), block.timestamp + 7 days);
        assertGt(yieldDistributor.rewardRate(), 0);
        assertEq(yieldDistributor.lastUpdateTime(), block.timestamp);
    }

    function test_distribute_revert_zeroAmount() public {
        vm.prank(distributor);
        vm.expectRevert(YieldDistributor.ZeroAmount.selector);
        yieldDistributor.distribute(0);
    }

    function test_distribute_revert_notDistributor() public {
        vm.prank(alice);
        vm.expectRevert();
        yieldDistributor.distribute(100 * UNIT);
    }

    function test_distribute_combinesWithRemaining() public {
        uint256 firstAmount = 100 * UNIT;
        uint256 secondAmount = 50 * UNIT;

        // First distribution
        vm.startPrank(distributor);
        vusd.approve(address(yieldDistributor), firstAmount + secondAmount);
        yieldDistributor.distribute(firstAmount);
        vm.stopPrank();

        // Fast forward halfway
        vm.warp(block.timestamp + 3.5 days);

        // Second distribution - should combine remaining ~50 with new 50
        vm.prank(distributor);
        yieldDistributor.distribute(secondAmount);

        // Period should be extended from current time
        assertEq(yieldDistributor.periodFinish(), block.timestamp + 7 days);
    }

    /*//////////////////////////////////////////////////////////////
                              PULL YIELD
    //////////////////////////////////////////////////////////////*/

    function test_pullYield_success() public {
        // Distribute yield
        vm.startPrank(distributor);
        vusd.approve(address(yieldDistributor), 100 * UNIT);
        yieldDistributor.distribute(100 * UNIT);
        vm.stopPrank();

        // Fast forward 1 day (1/7 of period)
        vm.warp(block.timestamp + 1 days);

        uint256 pendingBefore = yieldDistributor.pendingYield();
        assertGt(pendingBefore, 0);

        // Pull yield (called by vault)
        vm.prank(address(vault));
        uint256 pulled = yieldDistributor.pullYield();

        assertEq(pulled, pendingBefore);
        assertEq(vusd.balanceOf(address(vault)), pulled);
        assertEq(yieldDistributor.pendingYield(), 0);
    }

    function test_pullYield_revert_notVault() public {
        vm.prank(alice);
        vm.expectRevert(YieldDistributor.OnlyVault.selector);
        yieldDistributor.pullYield();
    }

    function test_pullYield_zeroWhenNothingDistributed() public {
        vm.prank(address(vault));
        uint256 pulled = yieldDistributor.pullYield();
        assertEq(pulled, 0);
    }

    function test_pullYield_multipleTimesInPeriod() public {
        // Distribute yield
        vm.startPrank(distributor);
        vusd.approve(address(yieldDistributor), 100 * UNIT);
        yieldDistributor.distribute(100 * UNIT);
        vm.stopPrank();

        uint256 totalPulled = 0;

        // Pull at day 1
        vm.warp(block.timestamp + 1 days);
        vm.prank(address(vault));
        totalPulled += yieldDistributor.pullYield();

        // Pull at day 3
        vm.warp(block.timestamp + 2 days);
        vm.prank(address(vault));
        totalPulled += yieldDistributor.pullYield();

        // Pull at day 7 (end)
        vm.warp(block.timestamp + 4 days);
        vm.prank(address(vault));
        totalPulled += yieldDistributor.pullYield();

        // Should have pulled approximately all yield (allow for rounding)
        assertApproxEqAbs(totalPulled, 100 * UNIT, 10);
    }

    /*//////////////////////////////////////////////////////////////
                            PENDING YIELD
    //////////////////////////////////////////////////////////////*/

    function test_pendingYield_calculation() public {
        // Distribute 70 UNIT over 7 days = 10 UNIT per day
        vm.startPrank(distributor);
        vusd.approve(address(yieldDistributor), 70 * UNIT);
        yieldDistributor.distribute(70 * UNIT);
        vm.stopPrank();

        // After 1 day, should have ~10 UNIT pending
        vm.warp(block.timestamp + 1 days);
        uint256 pending = yieldDistributor.pendingYield();
        assertApproxEqAbs(pending, 10 * UNIT, 10);

        // After 3.5 days, should have ~35 UNIT pending
        vm.warp(block.timestamp + 2.5 days);
        pending = yieldDistributor.pendingYield();
        assertApproxEqAbs(pending, 35 * UNIT, 10);
    }

    function test_pendingYield_capsAtPeriodFinish() public {
        // Distribute yield
        vm.startPrank(distributor);
        vusd.approve(address(yieldDistributor), 100 * UNIT);
        yieldDistributor.distribute(100 * UNIT);
        vm.stopPrank();

        // Fast forward past period
        vm.warp(block.timestamp + 14 days);

        // Pending should be capped at total distributed
        uint256 pending = yieldDistributor.pendingYield();
        assertApproxEqAbs(pending, 100 * UNIT, 10);
    }

    function test_pendingYield_zeroBeforeDistribution() public view {
        assertEq(yieldDistributor.pendingYield(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                          UPDATE YIELD DURATION
    //////////////////////////////////////////////////////////////*/

    function test_updateYieldDuration_success() public {
        vm.prank(owner);
        yieldDistributor.updateYieldDuration(14 days);

        assertEq(yieldDistributor.yieldDuration(), 14 days);
    }

    function test_updateYieldDuration_revert_belowMinimum() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(YieldDistributor.InvalidDuration.selector, 12 hours, 1 days));
        yieldDistributor.updateYieldDuration(12 hours);
    }

    function test_updateYieldDuration_revert_notOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        yieldDistributor.updateYieldDuration(14 days);
    }

    function test_updateYieldDuration_affectsFutureDistributions() public {
        // Update duration to 14 days
        vm.prank(owner);
        yieldDistributor.updateYieldDuration(14 days);

        // Distribute yield
        vm.startPrank(distributor);
        vusd.approve(address(yieldDistributor), 100 * UNIT);
        yieldDistributor.distribute(100 * UNIT);
        vm.stopPrank();

        // Period should be 14 days
        assertEq(yieldDistributor.periodFinish(), block.timestamp + 14 days);
    }

    /*//////////////////////////////////////////////////////////////
                          ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_grantDistributorRole() public {
        address newDistributor = makeAddr("newDistributor");
        bytes32 distributorRole = yieldDistributor.DISTRIBUTOR_ROLE();

        // Owner has DEFAULT_ADMIN_ROLE which can grant DISTRIBUTOR_ROLE
        vm.prank(owner);
        yieldDistributor.grantRole(distributorRole, newDistributor);

        assertTrue(yieldDistributor.hasRole(distributorRole, newDistributor));
    }

    function test_revokeDistributorRole() public {
        bytes32 distributorRole = yieldDistributor.DISTRIBUTOR_ROLE();

        // Owner has DEFAULT_ADMIN_ROLE which can revoke DISTRIBUTOR_ROLE
        vm.prank(owner);
        yieldDistributor.revokeRole(distributorRole, distributor);

        assertFalse(yieldDistributor.hasRole(distributorRole, distributor));
    }

    /*//////////////////////////////////////////////////////////////
                        INTEGRATION WITH VAULT
    //////////////////////////////////////////////////////////////*/

    function test_vaultPullsYieldOnDeposit() public {
        // Alice deposits first so totalSupply > 0 (yield is only pulled when shares exist)
        deal(address(vusd), alice, 200 * UNIT);
        vm.startPrank(alice);
        vusd.approve(address(vault), 200 * UNIT);
        vault.deposit(100 * UNIT, alice);
        vm.stopPrank();

        // Distribute yield
        vm.startPrank(distributor);
        vusd.approve(address(yieldDistributor), 100 * UNIT);
        yieldDistributor.distribute(100 * UNIT);
        vm.stopPrank();

        // Fast forward
        vm.warp(block.timestamp + 1 days);

        uint256 pendingBefore = yieldDistributor.pendingYield();
        assertGt(pendingBefore, 0);

        // Alice deposits again - this triggers pullYield
        vm.prank(alice);
        vault.deposit(100 * UNIT, alice);

        // Yield should have been pulled
        assertEq(yieldDistributor.pendingYield(), 0);
        assertGt(vault.totalAssets(), 200 * UNIT); // Includes pulled yield
    }

    function test_vaultPullsYieldOnRequestRedeem() public {
        // Setup: alice deposits first
        deal(address(vusd), alice, 100 * UNIT);
        vm.startPrank(alice);
        vusd.approve(address(vault), 100 * UNIT);
        vault.deposit(100 * UNIT, alice);
        vm.stopPrank();

        // Distribute yield
        vm.startPrank(distributor);
        vusd.approve(address(yieldDistributor), 50 * UNIT);
        yieldDistributor.distribute(50 * UNIT);
        vm.stopPrank();

        // Fast forward
        vm.warp(block.timestamp + 1 days);

        uint256 pendingBefore = yieldDistributor.pendingYield();
        assertGt(pendingBefore, 0);

        // Alice requests redeem - this triggers pullYield
        vm.prank(alice);
        vault.requestRedeem(50 * UNIT, alice);

        // Yield should have been pulled
        assertEq(yieldDistributor.pendingYield(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                          EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_distributeAfterPeriodEnds() public {
        // First distribution
        vm.startPrank(distributor);
        vusd.approve(address(yieldDistributor), 200 * UNIT);
        yieldDistributor.distribute(100 * UNIT);
        vm.stopPrank();

        // Fast forward past period
        vm.warp(block.timestamp + 10 days);

        // Second distribution after period ends
        vm.prank(distributor);
        yieldDistributor.distribute(100 * UNIT);

        // Should start fresh period
        assertEq(yieldDistributor.periodFinish(), block.timestamp + 7 days);
    }

    function test_pullYieldAfterPeriodEnds() public {
        // Distribute yield
        vm.startPrank(distributor);
        vusd.approve(address(yieldDistributor), 100 * UNIT);
        yieldDistributor.distribute(100 * UNIT);
        vm.stopPrank();

        // Fast forward way past period
        vm.warp(block.timestamp + 30 days);

        // Pull should get all yield
        vm.prank(address(vault));
        uint256 pulled = yieldDistributor.pullYield();

        assertApproxEqAbs(pulled, 100 * UNIT, 10);

        // Second pull should get nothing
        vm.prank(address(vault));
        uint256 secondPull = yieldDistributor.pullYield();
        assertEq(secondPull, 0);
    }

    function test_multiplePullsWithNoTimePassed() public {
        // Distribute yield
        vm.startPrank(distributor);
        vusd.approve(address(yieldDistributor), 100 * UNIT);
        yieldDistributor.distribute(100 * UNIT);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);

        // First pull
        vm.prank(address(vault));
        uint256 firstPull = yieldDistributor.pullYield();
        assertGt(firstPull, 0);

        // Immediate second pull (no time passed)
        vm.prank(address(vault));
        uint256 secondPull = yieldDistributor.pullYield();
        assertEq(secondPull, 0);
    }

    /// @notice Unpulled accrued yield must be included in subsequent distribute() calls.
    function test_accruedYieldOrphanedOnRedistribute() public {
        uint256 firstAmount = 70 * UNIT;
        uint256 secondAmount = 70 * UNIT;

        // Step 1: distribute(70) at day 0
        vm.startPrank(distributor);
        vusd.approve(address(yieldDistributor), firstAmount + secondAmount);
        yieldDistributor.distribute(firstAmount);
        vm.stopPrank();

        // rewardRate = 70 / 7 days = 10 tokens/day
        // periodFinish = day 7
        // contract balance = 70

        // Step 2: 3 days pass without any pullYield()
        vm.warp(block.timestamp + 3 days);

        // Accrued yield = 3 * 10 = 30 tokens
        // Remaining scheduled = 4 * 10 = 40 tokens
        uint256 accruedBeforeRedistribute = yieldDistributor.pendingYield();
        assertApproxEqAbs(accruedBeforeRedistribute, 30 * UNIT, 10, "accrued should be ~30");

        uint256 remainingRewards = (7 days - block.timestamp) * yieldDistributor.rewardRate() / PRECISION;

        // Step 3: distribute(70) at day 3 WITHOUT pulling first
        vm.prank(distributor);
        yieldDistributor.distribute(secondAmount);

        uint256 newRewardRate = yieldDistributor.rewardRate();

        uint256 totalRemaining = newRewardRate * 7 days / PRECISION;
        assertApproxEqAbs(totalRemaining, firstAmount + secondAmount, 10, "total remaining should be correct");

        // Step 4: Let the full new period complete and pull everything
        vm.warp(block.timestamp + 7 days);

        vm.prank(address(vault));
        uint256 totalPulled = yieldDistributor.pullYield();

        // After pulling, pendingYield = 0 and no more can ever be pulled
        assertEq(yieldDistributor.pendingYield(), 0, "no more pending after full period");

        // The contract should have transferred ALL tokens to the vault over the lifetime
        // Total distributed = 70 + 70 = 140
        // Total pullable should equal total distributed
        uint256 contractBalance = vusd.balanceOf(address(yieldDistributor));

        assertApproxEqAbs(contractBalance, 0, 5, "contract should have no remaining balance after full distribution");

        // Equivalently: total pulled should equal total deposited (140)
        assertApproxEqAbs(totalPulled, firstAmount + secondAmount, 10, "all distributed tokens should be pullable");
    }

    /// @notice Pending yield should be included when computing asset value on requestRedeem.
    function test_requestRedeem_shouldIncludePendingYield() public {
        // alice deposits 100 VUSD, gets 100 shares
        deal(address(vusd), alice, 100 * UNIT);
        vm.startPrank(alice);
        vusd.approve(address(vault), 100 * UNIT);
        vault.deposit(100 * UNIT, alice);
        vm.stopPrank();

        // distribute 10 VUSD yield
        deal(address(vusd), distributor, 10 * UNIT);
        vm.startPrank(distributor);
        vusd.approve(address(yieldDistributor), 10 * UNIT);
        yieldDistributor.distribute(10 * UNIT);
        vm.stopPrank();

        // time skip — full yield period elapses
        vm.warp(block.timestamp + 7 days);

        // alice requests redeem of ALL her shares
        vm.prank(alice);
        (, uint256 lockedAssets) = vault.requestRedeem(100 * UNIT, alice);

        // expected: 110 VUSD (100 original + 10 yield)
        assertApproxEqAbs(lockedAssets, 110 * UNIT, 10, "locked assets should be 110 VUSD");
    }

    /*//////////////////////////////////////////////////////////////
                              FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_distribute(uint256 amount) public {
        amount = bound(amount, 1, 1000 * UNIT);

        deal(address(vusd), distributor, amount);

        vm.startPrank(distributor);
        vusd.approve(address(yieldDistributor), amount);
        yieldDistributor.distribute(amount);
        vm.stopPrank();

        assertEq(vusd.balanceOf(address(yieldDistributor)), amount);
        assertEq(yieldDistributor.periodFinish(), block.timestamp + 7 days);
        assertGt(yieldDistributor.rewardRate(), 0);
        assertEq(yieldDistributor.lastUpdateTime(), block.timestamp);
    }

    function testFuzz_pendingYield_linearDistribution(uint256 amount, uint256 timeElapsed) public {
        amount = bound(amount, 100, 1000 * UNIT);
        timeElapsed = bound(timeElapsed, 1, 7 days);

        deal(address(vusd), distributor, amount);

        vm.startPrank(distributor);
        vusd.approve(address(yieldDistributor), amount);
        yieldDistributor.distribute(amount);
        vm.stopPrank();

        vm.warp(block.timestamp + timeElapsed);

        uint256 pending = yieldDistributor.pendingYield();
        uint256 expectedPending = (amount * timeElapsed) / 7 days;

        // Allow 1% tolerance for rounding
        assertApproxEqRel(pending, expectedPending, 0.01e18);
    }

    function testFuzz_pullYield(uint256 amount, uint256 timeElapsed) public {
        amount = bound(amount, 100, 1000 * UNIT);
        timeElapsed = bound(timeElapsed, 1, 7 days);

        deal(address(vusd), distributor, amount);

        vm.startPrank(distributor);
        vusd.approve(address(yieldDistributor), amount);
        yieldDistributor.distribute(amount);
        vm.stopPrank();

        vm.warp(block.timestamp + timeElapsed);

        uint256 pendingBefore = yieldDistributor.pendingYield();

        vm.prank(address(vault));
        uint256 pulled = yieldDistributor.pullYield();

        assertEq(pulled, pendingBefore);
        assertEq(yieldDistributor.pendingYield(), 0);
        assertEq(vusd.balanceOf(address(vault)), pulled);
    }

    function testFuzz_pullYield_fullPeriod(uint256 amount, uint256 timeElapsed) public {
        amount = bound(amount, 100, 1000 * UNIT);
        timeElapsed = bound(timeElapsed, 7 days, 365 days);

        deal(address(vusd), distributor, amount);

        vm.startPrank(distributor);
        vusd.approve(address(yieldDistributor), amount);
        yieldDistributor.distribute(amount);
        vm.stopPrank();

        vm.warp(block.timestamp + timeElapsed);

        vm.prank(address(vault));
        uint256 pulled = yieldDistributor.pullYield();

        // After full period, should get all yield
        assertApproxEqAbs(pulled, amount, 10);
    }

    function testFuzz_multipleDistributions(uint256 amount1, uint256 amount2, uint256 timeBetween) public {
        amount1 = bound(amount1, 100, 500 * UNIT);
        amount2 = bound(amount2, 100, 500 * UNIT);
        timeBetween = bound(timeBetween, 1, 6 days);

        deal(address(vusd), distributor, amount1 + amount2);

        vm.startPrank(distributor);
        vusd.approve(address(yieldDistributor), amount1 + amount2);
        yieldDistributor.distribute(amount1);

        vm.warp(block.timestamp + timeBetween);

        yieldDistributor.distribute(amount2);
        vm.stopPrank();

        // Period should be extended
        assertEq(yieldDistributor.periodFinish(), block.timestamp + 7 days);

        // _remaining includes accrued + future (from lastUpdateTime to periodFinish),
        // which equals the full amount1. So the new schedule total = amount1 + amount2.
        uint256 expectedRate = ((amount1 + amount2) * PRECISION) / 7 days;
        assertApproxEqRel(yieldDistributor.rewardRate(), expectedRate, 0.01e18);
    }

    function testFuzz_yieldDuration(uint256 duration, uint256 amount) public {
        duration = bound(duration, 1 days, 30 days);
        amount = bound(amount, 100, 1000 * UNIT);

        vm.prank(owner);
        yieldDistributor.updateYieldDuration(duration);

        deal(address(vusd), distributor, amount);

        vm.startPrank(distributor);
        vusd.approve(address(yieldDistributor), amount);
        yieldDistributor.distribute(amount);
        vm.stopPrank();

        assertEq(yieldDistributor.periodFinish(), block.timestamp + duration);

        // After full duration, should get all yield
        vm.warp(block.timestamp + duration);
        uint256 pending = yieldDistributor.pendingYield();
        assertApproxEqAbs(pending, amount, 10);
    }

    function testFuzz_multiplePulls(uint256 amount, uint8 numPulls) public {
        amount = bound(amount, 1000, 1000 * UNIT);
        numPulls = uint8(bound(numPulls, 2, 7)); // Limit to 7 to reduce rounding errors

        deal(address(vusd), distributor, amount);

        vm.startPrank(distributor);
        vusd.approve(address(yieldDistributor), amount);
        yieldDistributor.distribute(amount);
        vm.stopPrank();

        uint256 totalPulled = 0;
        uint256 timePerPull = 7 days / numPulls;

        for (uint256 i = 0; i < numPulls; i++) {
            vm.warp(block.timestamp + timePerPull);
            vm.prank(address(vault));
            totalPulled += yieldDistributor.pullYield();
        }

        // Should have pulled approximately all yield (allow 5% tolerance due to rounding)
        assertApproxEqRel(totalPulled, amount, 0.05e18);
    }

    function testFuzz_distributeAfterPeriodEnds(uint256 amount1, uint256 amount2, uint256 timeAfterPeriod) public {
        amount1 = bound(amount1, 100, 500 * UNIT);
        amount2 = bound(amount2, 100, 500 * UNIT);
        timeAfterPeriod = bound(timeAfterPeriod, 1, 30 days);

        deal(address(vusd), distributor, amount1 + amount2);

        vm.startPrank(distributor);
        vusd.approve(address(yieldDistributor), amount1 + amount2);
        yieldDistributor.distribute(amount1);

        // Fast forward past period
        vm.warp(block.timestamp + 7 days + timeAfterPeriod);

        // First pull all accumulated yield
        vm.stopPrank();
        vm.prank(address(vault));
        uint256 firstPull = yieldDistributor.pullYield();
        assertApproxEqAbs(firstPull, amount1, 10);

        // Distribute again
        vm.prank(distributor);
        yieldDistributor.distribute(amount2);

        // Should start fresh period
        assertEq(yieldDistributor.periodFinish(), block.timestamp + 7 days);

        // After new period, should get new amount
        vm.warp(block.timestamp + 7 days);
        vm.prank(address(vault));
        uint256 secondPull = yieldDistributor.pullYield();
        assertApproxEqAbs(secondPull, amount2, 10);
    }
}
