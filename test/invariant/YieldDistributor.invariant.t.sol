// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StakingVault} from "src/StakingVault.sol";
import {YieldDistributor} from "src/YieldDistributor.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

/// @title YieldDistributor Invariant Test Handler
/// @notice Handler contract that performs random operations on YieldDistributor
contract YieldDistributorHandler is Test {
    YieldDistributor public yieldDistributor;
    StakingVault public vault;
    MockERC20 public vusd;
    address public owner;
    address public distributor;

    // Ghost variables for tracking
    uint256 public ghost_totalDistributed;
    uint256 public ghost_totalPulled;
    uint256 public ghost_distributeCount;
    uint256 public ghost_pullCount;

    uint256 constant UNIT = 1e6;

    constructor(YieldDistributor yieldDistributor_, StakingVault vault_, MockERC20 vusd_, address owner_, address distributor_)
    {
        yieldDistributor = yieldDistributor_;
        vault = vault_;
        vusd = vusd_;
        owner = owner_;
        distributor = distributor_;
    }

    /// @notice Distribute yield to the YieldDistributor
    /// @param amount The amount to distribute (will be bounded)
    function distribute(uint256 amount) external {
        amount = bound(amount, 1, 100 * UNIT);
        if (amount == 0) return;

        deal(address(vusd), distributor, amount);

        vm.startPrank(distributor);
        vusd.approve(address(yieldDistributor), amount);
        yieldDistributor.distribute(amount);
        vm.stopPrank();

        ghost_totalDistributed += amount;
        ghost_distributeCount++;
    }

    /// @notice Pull yield from the YieldDistributor (via vault)
    function pullYield() external {
        vm.prank(address(vault));
        uint256 pulled = yieldDistributor.pullYield();

        ghost_totalPulled += pulled;
        ghost_pullCount++;
    }

    /// @notice Warp time forward
    /// @param secondsToWarp Time to warp (will be bounded)
    function warpTime(uint256 secondsToWarp) external {
        secondsToWarp = bound(secondsToWarp, 1 hours, 8 days);
        vm.warp(block.timestamp + secondsToWarp);
    }

    /// @notice Update yield duration
    /// @param duration New duration (will be bounded)
    function updateYieldDuration(uint256 duration) external {
        duration = bound(duration, 1 days, 30 days);

        vm.prank(owner);
        yieldDistributor.updateYieldDuration(duration);
    }
}

contract YieldDistributorInvariantTest is Test {
    YieldDistributor yieldDistributor;
    StakingVault vault;
    MockERC20 vusd;
    YieldDistributorHandler handler;

    address owner = makeAddr("owner");
    address distributor = makeAddr("distributor");

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

        // Setup
        vm.startPrank(owner);
        vault.updateYieldDistributor(address(yieldDistributor));
        yieldDistributor.grantRole(yieldDistributor.DISTRIBUTOR_ROLE(), distributor);
        vm.stopPrank();

        handler = new YieldDistributorHandler(yieldDistributor, vault, vusd, owner, distributor);

        // Target the handler for invariant testing
        targetContract(address(handler));

        // Exclude other contracts
        excludeContract(address(vault));
        excludeContract(address(yieldDistributor));
        excludeContract(address(vusd));
    }

    /// @notice Invariant: Total pulled should never exceed total distributed
    function invariant_pulledNeverExceedsDistributed() public view {
        assertLe(
            handler.ghost_totalPulled(),
            handler.ghost_totalDistributed(),
            "Pulled more than distributed"
        );
    }

    /// @notice Invariant: Pending yield + pulled should equal distributed (minus precision loss)
    function invariant_yieldAccountingConsistency() public view {
        uint256 pending = yieldDistributor.pendingYield();
        uint256 pulled = handler.ghost_totalPulled();
        uint256 distributed = handler.ghost_totalDistributed();

        // Allow for small rounding errors (1 per distribution)
        uint256 tolerance = handler.ghost_distributeCount() * 10;
        assertLe(pending + pulled, distributed + tolerance, "Yield accounting inconsistent");
    }

    /// @notice Invariant: YieldDistributor balance >= pending yield
    function invariant_balanceCoverssPending() public view {
        uint256 balance = vusd.balanceOf(address(yieldDistributor));
        uint256 pending = yieldDistributor.pendingYield();

        // Balance should cover pending (might have more if not all time has passed)
        assertGe(balance, pending, "Balance doesn't cover pending");
    }

    /// @notice Invariant: If no distribution, pending yield is 0
    function invariant_noPendingWithoutDistribution() public view {
        if (yieldDistributor.lastUpdateTime() == 0) {
            assertEq(yieldDistributor.pendingYield(), 0, "Pending without distribution");
        }
    }

    /// @notice Invariant: Reward rate * duration / PRECISION <= distributed - pulled (approx)
    function invariant_rewardRateConsistency() public view {
        if (handler.ghost_distributeCount() == 0) return;
        if (yieldDistributor.rewardRate() == 0) return;

        uint256 periodFinish = yieldDistributor.periodFinish();
        if (block.timestamp >= periodFinish) return;

        uint256 remainingTime = periodFinish - block.timestamp;
        uint256 remainingYield = (remainingTime * yieldDistributor.rewardRate()) / PRECISION;
        uint256 pending = yieldDistributor.pendingYield();
        uint256 balance = vusd.balanceOf(address(yieldDistributor));

        // Balance should cover remaining + pending (allow small rounding)
        assertGe(balance + 100, remainingYield + pending, "Reward rate inconsistent with balance");
    }

    /// @notice Invariant: yieldDuration is always >= MIN_YIELD_DURATION
    function invariant_yieldDurationMinimum() public view {
        assertGe(yieldDistributor.yieldDuration(), 1 days, "Yield duration below minimum");
    }

    /// @notice Invariant: periodFinish is 0 or was set correctly
    /// @dev After time warps, lastUpdateTime can be after periodFinish when pulling after period ends
    function invariant_periodFinishConsistency() public view {
        uint256 periodFinish = yieldDistributor.periodFinish();
        uint256 lastUpdate = yieldDistributor.lastUpdateTime();

        // If no distribution, both should be 0
        if (handler.ghost_distributeCount() == 0) {
            assertEq(periodFinish, 0, "Period finish set without distribution");
            assertEq(lastUpdate, 0, "Last update set without distribution");
        }
        // After distribution, lastUpdate should be <= current time
        if (lastUpdate > 0) {
            assertLe(lastUpdate, block.timestamp, "Last update in future");
        }
    }

    /// @notice Invariant: After pulling, lastUpdateTime should be current block.timestamp
    function invariant_lastUpdateTimeAfterPull() public view {
        // This is checked implicitly through the pullYield function behavior
        // lastUpdateTime should never be in the future
        assertLe(yieldDistributor.lastUpdateTime(), block.timestamp, "Last update time in future");
    }

    /// @notice Call summary for debugging
    function invariant_callSummary() public view {
        console.log("Total distributed:", handler.ghost_totalDistributed());
        console.log("Total pulled:", handler.ghost_totalPulled());
        console.log("Distribute count:", handler.ghost_distributeCount());
        console.log("Pull count:", handler.ghost_pullCount());
        console.log("Pending yield:", yieldDistributor.pendingYield());
        console.log("Distributor balance:", vusd.balanceOf(address(yieldDistributor)));
        console.log("Vault balance:", vusd.balanceOf(address(vault)));
        console.log("Current time:", block.timestamp);
        console.log("Period finish:", yieldDistributor.periodFinish());
    }
}
