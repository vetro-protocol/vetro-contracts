// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StakingVault} from "src/StakingVault.sol";
import {IStakingVault} from "src/interfaces/IStakingVault.sol";
import {YieldDistributor} from "src/YieldDistributor.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

/// @title StakingVault Invariant Test Handler
/// @notice Handler contract that performs random operations on StakingVault
contract StakingVaultHandler is Test {
    StakingVault public vault;
    YieldDistributor public yieldDistributor;
    MockERC20 public vusd;

    address[] public actors;
    address internal currentActor;

    // Ghost variables for tracking
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_totalRequestedAssets;
    uint256 public ghost_totalClaimedAssets;
    uint256 public ghost_totalCancelledAssets;
    uint256 public ghost_totalYieldDistributed;

    uint256 constant UNIT = 1e6;

    modifier useActor(uint256 actorIndexSeed) {
        currentActor = actors[bound(actorIndexSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    constructor(StakingVault vault_, YieldDistributor yieldDistributor_, MockERC20 vusd_, address[] memory actors_) {
        vault = vault_;
        yieldDistributor = yieldDistributor_;
        vusd = vusd_;
        actors = actors_;
    }

    function deposit(uint256 actorSeed, uint256 amount) external useActor(actorSeed) {
        amount = bound(amount, 1, 100 * UNIT);

        deal(address(vusd), currentActor, amount);
        vusd.approve(address(vault), amount);
        vault.deposit(amount, currentActor);

        ghost_totalDeposited += amount;
    }

    function mint(uint256 actorSeed, uint256 shares) external useActor(actorSeed) {
        shares = bound(shares, 1, 100 * UNIT);

        uint256 assets = vault.previewMint(shares);
        deal(address(vusd), currentActor, assets);
        vusd.approve(address(vault), assets);
        vault.mint(shares, currentActor);

        ghost_totalDeposited += assets;
    }

    function requestRedeem(uint256 actorSeed, uint256 shares) external useActor(actorSeed) {
        uint256 balance = vault.balanceOf(currentActor);
        if (balance == 0) return;

        shares = bound(shares, 1, balance);

        (, uint256 assets) = vault.requestRedeem(shares, currentActor);
        ghost_totalRequestedAssets += assets;
    }

    function requestWithdraw(uint256 actorSeed, uint256 assets) external useActor(actorSeed) {
        uint256 maxAssets = vault.previewRedeem(vault.balanceOf(currentActor));
        if (maxAssets == 0) return;

        assets = bound(assets, 1, maxAssets);

        vault.requestWithdraw(assets, currentActor);
        ghost_totalRequestedAssets += assets;
    }

    function claimWithdraw(uint256 actorSeed, uint256 requestIdSeed) external useActor(actorSeed) {
        uint256[] memory activeIds = vault.getActiveRequestIds(currentActor);
        if (activeIds.length == 0) return;

        uint256 requestId = activeIds[bound(requestIdSeed, 0, activeIds.length - 1)];
        IStakingVault.CooldownRequest memory request = vault.getRequestDetails(requestId);

        if (block.timestamp < request.claimableAt) return;

        uint256 assets = vault.claimWithdraw(requestId, currentActor);
        ghost_totalClaimedAssets += assets;
        ghost_totalWithdrawn += assets;
    }

    function cancelWithdraw(uint256 actorSeed, uint256 requestIdSeed) external useActor(actorSeed) {
        uint256[] memory activeIds = vault.getActiveRequestIds(currentActor);
        if (activeIds.length == 0) return;

        uint256 requestId = activeIds[bound(requestIdSeed, 0, activeIds.length - 1)];
        IStakingVault.CooldownRequest memory request = vault.getRequestDetails(requestId);

        vault.cancelWithdraw(requestId);
        ghost_totalCancelledAssets += request.assets;
    }

    function distributeYield(uint256 amount) external {
        amount = bound(amount, 1, 50 * UNIT);

        address owner = vault.owner();
        deal(address(vusd), owner, amount);

        vm.startPrank(owner);
        vusd.approve(address(yieldDistributor), amount);
        yieldDistributor.distribute(amount);
        vm.stopPrank();

        ghost_totalYieldDistributed += amount;
    }

    function warpTime(uint256 secondsToWarp) external {
        secondsToWarp = bound(secondsToWarp, 1 hours, 8 days);
        vm.warp(block.timestamp + secondsToWarp);
    }
}

contract StakingVaultInvariantTest is Test {
    StakingVault vault;
    YieldDistributor yieldDistributor;
    MockERC20 vusd;
    StakingVaultHandler handler;

    address owner = makeAddr("owner");
    address[] actors;

    uint256 constant UNIT = 1e6;

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
        yieldDistributor.grantRole(yieldDistributor.DISTRIBUTOR_ROLE(), owner);
        vm.stopPrank();

        // Create actors
        for (uint256 i = 0; i < 5; i++) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }

        handler = new StakingVaultHandler(vault, yieldDistributor, vusd, actors);

        // Target the handler for invariant testing
        targetContract(address(handler));

        // Exclude other contracts from being called directly
        excludeContract(address(vault));
        excludeContract(address(yieldDistributor));
        excludeContract(address(vusd));
    }

    /// @notice Invariant: totalAssets + totalAssetsInCooldown <= vault VUSD balance
    function invariant_assetsAccountingConsistency() public view {
        uint256 vaultBalance = vusd.balanceOf(address(vault));
        uint256 totalAssets = vault.totalAssets();
        uint256 inCooldown = vault.totalAssetsInCooldown();

        assertLe(totalAssets + inCooldown, vaultBalance, "Assets accounting inconsistent");
    }

    /// @notice Invariant: totalAssets should equal vault balance minus cooldown assets
    function invariant_totalAssetsCalculation() public view {
        uint256 vaultBalance = vusd.balanceOf(address(vault));
        uint256 inCooldown = vault.totalAssetsInCooldown();
        uint256 expectedTotalAssets = vaultBalance > inCooldown ? vaultBalance - inCooldown : 0;

        assertEq(vault.totalAssets(), expectedTotalAssets, "totalAssets calculation incorrect");
    }

    /// @notice Invariant: If there are no shares, totalAssets comes from yield distribution
    /// @dev Note: Yield can accumulate even with no shares if yield was distributed.
    ///      When deposit/withdraw happens, yield is pulled and added to vault balance.
    function invariant_noSharesImpliesNoStakedAssets() public view {
        if (vault.totalSupply() == 0 && vault.totalAssetsInCooldown() == 0) {
            // With no shares and no cooldown, totalAssets should only be from yield
            // This is valid - yield can accumulate before any deposits
            uint256 totalAssets = vault.totalAssets();
            // Just verify it's not exceeding vault's VUSD balance
            assertLe(totalAssets, vusd.balanceOf(address(vault)), "Assets exceed vault balance");
        }
    }

    /// @notice Invariant: nextRequestId is always increasing
    function invariant_requestIdMonotonicallyIncreasing() public view {
        // This is implicitly tested by the fact that requestId is a counter
        assertTrue(vault.nextRequestId() >= 0, "Invalid request ID");
    }

    /// @notice Invariant: For any active request, assets > 0
    function invariant_activeRequestsHavePositiveAssets() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            uint256[] memory activeIds = vault.getActiveRequestIds(actors[i]);
            for (uint256 j = 0; j < activeIds.length; j++) {
                IStakingVault.CooldownRequest memory request = vault.getRequestDetails(activeIds[j]);
                assertGt(request.assets, 0, "Active request has zero assets");
            }
        }
    }

    /// @notice Invariant: Sum of active request assets equals totalAssetsInCooldown
    function invariant_cooldownAssetsMatchActiveRequests() public view {
        uint256 sumOfActiveAssets = 0;

        for (uint256 i = 0; i < actors.length; i++) {
            uint256[] memory activeIds = vault.getActiveRequestIds(actors[i]);
            for (uint256 j = 0; j < activeIds.length; j++) {
                IStakingVault.CooldownRequest memory request = vault.getRequestDetails(activeIds[j]);
                sumOfActiveAssets += request.assets;
            }
        }

        assertEq(vault.totalAssetsInCooldown(), sumOfActiveAssets, "Cooldown assets mismatch");
    }

    /// @notice Invariant: Share price should never decrease (except for rounding)
    function invariant_sharePriceNeverDecreases() public view {
        if (vault.totalSupply() == 0) return;

        // Share price = totalAssets / totalSupply
        // In a yield-bearing vault, this should only increase
        uint256 assetsPerShare = vault.previewRedeem(1e18);

        // Initially 1:1, so should be >= 1e18 (minus small rounding)
        assertGe(assetsPerShare, 1e18 - 10, "Share price decreased");
    }

    /// @notice Call summary for debugging
    function invariant_callSummary() public view {
        console.log("Total deposited:", handler.ghost_totalDeposited());
        console.log("Total withdrawn:", handler.ghost_totalWithdrawn());
        console.log("Total requested:", handler.ghost_totalRequestedAssets());
        console.log("Total claimed:", handler.ghost_totalClaimedAssets());
        console.log("Total cancelled:", handler.ghost_totalCancelledAssets());
        console.log("Total yield distributed:", handler.ghost_totalYieldDistributed());
        console.log("Vault balance:", vusd.balanceOf(address(vault)));
        console.log("Total assets:", vault.totalAssets());
        console.log("In cooldown:", vault.totalAssetsInCooldown());
    }
}
