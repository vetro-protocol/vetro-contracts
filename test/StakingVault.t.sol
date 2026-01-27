// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StakingVault} from "src/StakingVault.sol";
import {IStakingVault} from "src/interfaces/IStakingVault.sol";
import {YieldDistributor} from "src/YieldDistributor.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract StakingVaultTest is Test {
    StakingVault vault;
    YieldDistributor yieldDistributor;
    MockERC20 vusd;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    uint256 constant UNIT = 1e6; // VUSD has 6 decimals

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

        // Setup yield distributor
        vm.startPrank(owner);
        vault.updateYieldDistributor(address(yieldDistributor));
        yieldDistributor.grantRole(yieldDistributor.DISTRIBUTOR_ROLE(), owner);
        vm.stopPrank();

        // Give users some VUSD
        deal(address(vusd), alice, 1000 * UNIT);
        deal(address(vusd), bob, 1000 * UNIT);
        deal(address(vusd), charlie, 1000 * UNIT);
    }

    /*//////////////////////////////////////////////////////////////
                              INITIALIZE
    //////////////////////////////////////////////////////////////*/

    function test_initialize_success() public view {
        assertEq(vault.asset(), address(vusd));
        assertEq(vault.name(), "Staked VUSD");
        assertEq(vault.symbol(), "sVUSD");
        assertEq(vault.owner(), owner);
        assertEq(vault.cooldownDuration(), 7 days);
        assertTrue(vault.cooldownEnabled());
    }

    function test_initialize_revert_zeroAsset() public {
        StakingVault newVaultImpl = new StakingVault();
        vm.expectRevert(StakingVault.ZeroAddress.selector);
        new ERC1967Proxy(
            address(newVaultImpl), abi.encodeCall(StakingVault.initialize, (address(0), "Staked VUSD", "sVUSD", owner))
        );
    }

    function test_initialize_revert_zeroOwner() public {
        StakingVault newVaultImpl = new StakingVault();
        vm.expectRevert(StakingVault.ZeroAddress.selector);
        new ERC1967Proxy(
            address(newVaultImpl),
            abi.encodeCall(StakingVault.initialize, (address(vusd), "Staked VUSD", "sVUSD", address(0)))
        );
    }

    function test_initialize_revert_alreadyInitialized() public {
        vm.expectRevert();
        vault.initialize(address(vusd), "Staked VUSD", "sVUSD", owner);
    }

    /*//////////////////////////////////////////////////////////////
                              DEPOSIT/MINT
    //////////////////////////////////////////////////////////////*/

    function test_deposit_success() public {
        uint256 depositAmount = 100 * UNIT;

        vm.startPrank(alice);
        vusd.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, alice);
        vm.stopPrank();

        assertEq(shares, depositAmount); // 1:1 initially
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.totalAssets(), depositAmount);
    }

    function test_mint_success() public {
        uint256 sharesToMint = 100 * UNIT;

        vm.startPrank(alice);
        vusd.approve(address(vault), sharesToMint);
        uint256 assets = vault.mint(sharesToMint, alice);
        vm.stopPrank();

        assertEq(assets, sharesToMint); // 1:1 initially
        assertEq(vault.balanceOf(alice), sharesToMint);
    }

    /*//////////////////////////////////////////////////////////////
                         INSTANT WITHDRAW (WHITELISTED)
    //////////////////////////////////////////////////////////////*/

    function test_withdraw_revert_whenCooldownEnabled() public {
        // Deposit first
        vm.startPrank(alice);
        vusd.approve(address(vault), 100 * UNIT);
        vault.deposit(100 * UNIT, alice);

        // Try to withdraw - should fail
        vm.expectRevert(StakingVault.CooldownEnabled.selector);
        vault.withdraw(50 * UNIT, alice, alice);
        vm.stopPrank();
    }

    function test_redeem_revert_whenCooldownEnabled() public {
        // Deposit first
        vm.startPrank(alice);
        vusd.approve(address(vault), 100 * UNIT);
        vault.deposit(100 * UNIT, alice);

        // Try to redeem - should fail
        vm.expectRevert(StakingVault.CooldownEnabled.selector);
        vault.redeem(50 * UNIT, alice, alice);
        vm.stopPrank();
    }

    function test_withdraw_success_whenWhitelisted() public {
        // Whitelist alice
        vm.prank(owner);
        vault.updateInstantWithdrawWhitelist(alice, true);

        // Deposit
        vm.startPrank(alice);
        vusd.approve(address(vault), 100 * UNIT);
        vault.deposit(100 * UNIT, alice);

        // Withdraw should succeed
        uint256 shares = vault.withdraw(50 * UNIT, alice, alice);
        vm.stopPrank();

        assertEq(vusd.balanceOf(alice), 950 * UNIT); // 1000 - 100 + 50
        assertEq(vault.balanceOf(alice), 50 * UNIT);
    }

    function test_withdraw_success_whenCooldownDisabled() public {
        // Disable cooldown
        vm.prank(owner);
        vault.updateCooldownEnabled(false);

        // Deposit
        vm.startPrank(alice);
        vusd.approve(address(vault), 100 * UNIT);
        vault.deposit(100 * UNIT, alice);

        // Withdraw should succeed
        vault.withdraw(50 * UNIT, alice, alice);
        vm.stopPrank();

        assertEq(vusd.balanceOf(alice), 950 * UNIT);
    }

    /*//////////////////////////////////////////////////////////////
                         REQUEST REDEEM (COOLDOWN)
    //////////////////////////////////////////////////////////////*/

    function test_requestRedeem_success() public {
        // Deposit first
        vm.startPrank(alice);
        vusd.approve(address(vault), 100 * UNIT);
        vault.deposit(100 * UNIT, alice);

        // Request redeem
        (uint256 requestId, uint256 assets) = vault.requestRedeem(50 * UNIT, alice);
        vm.stopPrank();

        assertEq(requestId, 0);
        assertEq(assets, 50 * UNIT);
        assertEq(vault.balanceOf(alice), 50 * UNIT); // Shares burned
        assertEq(vault.totalAssetsInCooldown(), 50 * UNIT);

        // Check request details
        IStakingVault.CooldownRequest memory request = vault.getRequestDetails(requestId);
        assertEq(request.owner, alice);
        assertEq(request.assets, 50 * UNIT);
        assertEq(request.claimableAt, block.timestamp + 7 days);
    }

    function test_requestRedeem_revert_zeroShares() public {
        vm.prank(alice);
        vm.expectRevert(StakingVault.ZeroShares.selector);
        vault.requestRedeem(0, alice);
    }

    function test_requestRedeem_revert_insufficientShares() public {
        vm.prank(alice);
        // ERC20 reverts with ERC20InsufficientBalance when trying to burn more than balance
        vm.expectRevert();
        vault.requestRedeem(100 * UNIT, alice);
    }

    function test_requestRedeem_revert_whenCooldownDisabled() public {
        vm.prank(owner);
        vault.updateCooldownEnabled(false);

        vm.prank(alice);
        vm.expectRevert(StakingVault.CooldownNotEnabled.selector);
        vault.requestRedeem(50 * UNIT, alice);
    }

    function test_requestRedeem_withAllowance() public {
        // Deposit as alice
        vm.startPrank(alice);
        vusd.approve(address(vault), 100 * UNIT);
        vault.deposit(100 * UNIT, alice);
        vault.approve(bob, 50 * UNIT);
        vm.stopPrank();

        // Bob requests redeem on behalf of alice
        vm.prank(bob);
        (uint256 requestId, uint256 assets) = vault.requestRedeem(50 * UNIT, alice);

        assertEq(requestId, 0);
        assertEq(assets, 50 * UNIT);
        assertEq(vault.balanceOf(alice), 50 * UNIT);
        assertEq(vault.allowance(alice, bob), 0); // Allowance spent
    }

    /*//////////////////////////////////////////////////////////////
                         REQUEST WITHDRAW (COOLDOWN)
    //////////////////////////////////////////////////////////////*/

    function test_requestWithdraw_success() public {
        // Deposit first
        vm.startPrank(alice);
        vusd.approve(address(vault), 100 * UNIT);
        vault.deposit(100 * UNIT, alice);

        // Request withdraw by assets
        (uint256 requestId, uint256 shares) = vault.requestWithdraw(50 * UNIT, alice);
        vm.stopPrank();

        assertEq(requestId, 0);
        assertEq(shares, 50 * UNIT); // 1:1 ratio
        assertEq(vault.balanceOf(alice), 50 * UNIT);
    }

    function test_requestWithdraw_revert_zeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(StakingVault.ZeroAmount.selector);
        vault.requestWithdraw(0, alice);
    }

    /*//////////////////////////////////////////////////////////////
                            CLAIM WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function test_claimWithdraw_success() public {
        // Setup: deposit and request
        vm.startPrank(alice);
        vusd.approve(address(vault), 100 * UNIT);
        vault.deposit(100 * UNIT, alice);
        (uint256 requestId,) = vault.requestRedeem(50 * UNIT, alice);
        vm.stopPrank();

        // Fast forward past cooldown
        vm.warp(block.timestamp + 7 days);

        // Claim
        vm.prank(alice);
        uint256 assets = vault.claimWithdraw(requestId, alice);

        assertEq(assets, 50 * UNIT);
        assertEq(vusd.balanceOf(alice), 950 * UNIT); // 1000 - 100 + 50
        assertEq(vault.totalAssetsInCooldown(), 0);

        // Check request is deleted
        IStakingVault.CooldownRequest memory request = vault.getRequestDetails(requestId);
        assertEq(request.owner, address(0));
        assertEq(request.assets, 0);
    }

    function test_claimWithdraw_toReceiver() public {
        // Setup: deposit and request
        vm.startPrank(alice);
        vusd.approve(address(vault), 100 * UNIT);
        vault.deposit(100 * UNIT, alice);
        (uint256 requestId,) = vault.requestRedeem(50 * UNIT, alice);
        vm.stopPrank();

        // Fast forward past cooldown
        vm.warp(block.timestamp + 7 days);

        // Claim to bob
        vm.prank(alice);
        vault.claimWithdraw(requestId, bob);

        assertEq(vusd.balanceOf(bob), 1050 * UNIT); // 1000 + 50
        assertEq(vusd.balanceOf(alice), 900 * UNIT); // 1000 - 100
    }

    function test_claimWithdraw_revert_notMatured() public {
        // Setup: deposit and request
        vm.startPrank(alice);
        vusd.approve(address(vault), 100 * UNIT);
        vault.deposit(100 * UNIT, alice);
        (uint256 requestId,) = vault.requestRedeem(50 * UNIT, alice);

        // Try to claim before cooldown
        vm.expectRevert(
            abi.encodeWithSelector(StakingVault.CooldownNotMatured.selector, requestId, block.timestamp + 7 days)
        );
        vault.claimWithdraw(requestId, alice);
        vm.stopPrank();
    }

    function test_claimWithdraw_revert_alreadyClaimed() public {
        // Setup: deposit, request, claim
        vm.startPrank(alice);
        vusd.approve(address(vault), 100 * UNIT);
        vault.deposit(100 * UNIT, alice);
        (uint256 requestId,) = vault.requestRedeem(50 * UNIT, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days);

        vm.startPrank(alice);
        vault.claimWithdraw(requestId, alice);

        // Try to claim again - request was deleted so assets == 0
        vm.expectRevert(abi.encodeWithSelector(StakingVault.InvalidRequestId.selector, requestId));
        vault.claimWithdraw(requestId, alice);
        vm.stopPrank();
    }

    function test_claimWithdraw_revert_notOwner() public {
        // Setup: deposit and request
        vm.startPrank(alice);
        vusd.approve(address(vault), 100 * UNIT);
        vault.deposit(100 * UNIT, alice);
        (uint256 requestId,) = vault.requestRedeem(50 * UNIT, alice);
        vm.stopPrank();

        // Fast forward past cooldown
        vm.warp(block.timestamp + 7 days);

        // Bob tries to claim alice's request - should fail even with allowance
        vm.prank(alice);
        vault.approve(bob, type(uint256).max);

        vm.prank(bob);
        vm.expectRevert(StakingVault.NotRequestOwner.selector);
        vault.claimWithdraw(requestId, bob);
    }

    function test_claimWithdraw_revert_invalidRequestId() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.InvalidRequestId.selector, 999));
        vault.claimWithdraw(999, alice);
    }

    function test_claimWithdraw_revert_zeroReceiver() public {
        // Setup: deposit and request
        vm.startPrank(alice);
        vusd.approve(address(vault), 100 * UNIT);
        vault.deposit(100 * UNIT, alice);
        (uint256 requestId,) = vault.requestRedeem(50 * UNIT, alice);
        vm.stopPrank();

        // Fast forward past cooldown
        vm.warp(block.timestamp + 7 days);

        // Try to claim with zero receiver
        vm.prank(alice);
        vm.expectRevert(StakingVault.ZeroAddress.selector);
        vault.claimWithdraw(requestId, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                          CLAIM WITHDRAW BATCH
    //////////////////////////////////////////////////////////////*/

    function test_claimWithdrawBatch_success() public {
        // Setup: deposit and create multiple requests
        vm.startPrank(alice);
        vusd.approve(address(vault), 100 * UNIT);
        vault.deposit(100 * UNIT, alice);
        (uint256 requestId1,) = vault.requestRedeem(30 * UNIT, alice);
        (uint256 requestId2,) = vault.requestRedeem(20 * UNIT, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days);

        uint256[] memory requestIds = new uint256[](2);
        requestIds[0] = requestId1;
        requestIds[1] = requestId2;

        vm.prank(alice);
        uint256 totalAssets = vault.claimWithdrawBatch(requestIds, alice);

        assertEq(totalAssets, 50 * UNIT);
        assertEq(vusd.balanceOf(alice), 950 * UNIT);
    }

    /*//////////////////////////////////////////////////////////////
                           CANCEL WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function test_cancelWithdraw_success() public {
        // Setup: deposit and request
        vm.startPrank(alice);
        vusd.approve(address(vault), 100 * UNIT);
        vault.deposit(100 * UNIT, alice);
        (uint256 requestId, uint256 lockedAssets) = vault.requestRedeem(50 * UNIT, alice);

        uint256 sharesBefore = vault.balanceOf(alice);
        uint256 cooldownBefore = vault.totalAssetsInCooldown();

        // Cancel
        uint256 shares = vault.cancelWithdraw(requestId);
        vm.stopPrank();

        // Verify shares were returned
        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), sharesBefore + shares);
        assertEq(vault.totalAssetsInCooldown(), cooldownBefore - lockedAssets);

        // Check request is deleted
        IStakingVault.CooldownRequest memory request = vault.getRequestDetails(requestId);
        assertEq(request.owner, address(0));
        assertEq(request.assets, 0);
    }

    function test_cancelWithdraw_revert_notOwner() public {
        // Setup: deposit and request
        vm.startPrank(alice);
        vusd.approve(address(vault), 100 * UNIT);
        vault.deposit(100 * UNIT, alice);
        (uint256 requestId,) = vault.requestRedeem(50 * UNIT, alice);
        vm.stopPrank();

        // Alice approves bob - but allowance should not permit cancel
        vm.prank(alice);
        vault.approve(bob, 100 * UNIT);

        // Bob tries to cancel on behalf of alice - should fail
        vm.prank(bob);
        vm.expectRevert(StakingVault.NotRequestOwner.selector);
        vault.cancelWithdraw(requestId);

        // Verify request is still active (not deleted)
        IStakingVault.CooldownRequest memory request = vault.getRequestDetails(requestId);
        assertEq(request.owner, alice);
        assertGt(request.assets, 0);
    }

    function test_cancelWithdraw_revert_alreadyClaimed() public {
        // Setup: deposit, request, claim
        vm.startPrank(alice);
        vusd.approve(address(vault), 100 * UNIT);
        vault.deposit(100 * UNIT, alice);
        (uint256 requestId,) = vault.requestRedeem(50 * UNIT, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days);

        vm.startPrank(alice);
        vault.claimWithdraw(requestId, alice);

        // Try to cancel - request was deleted so assets == 0
        vm.expectRevert(abi.encodeWithSelector(StakingVault.InvalidRequestId.selector, requestId));
        vault.cancelWithdraw(requestId);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                           GLOBAL REQUEST IDS
    //////////////////////////////////////////////////////////////*/

    function test_globalRequestIds_unique() public {
        // Alice deposits and requests
        vm.startPrank(alice);
        vusd.approve(address(vault), 100 * UNIT);
        vault.deposit(100 * UNIT, alice);
        (uint256 aliceRequestId,) = vault.requestRedeem(50 * UNIT, alice);
        vm.stopPrank();

        // Bob deposits and requests
        vm.startPrank(bob);
        vusd.approve(address(vault), 100 * UNIT);
        vault.deposit(100 * UNIT, bob);
        (uint256 bobRequestId,) = vault.requestRedeem(50 * UNIT, bob);
        vm.stopPrank();

        // Request IDs should be globally unique
        assertEq(aliceRequestId, 0);
        assertEq(bobRequestId, 1);
        assertEq(vault.nextRequestId(), 2);

        // Verify ownership
        assertEq(vault.getRequestDetails(aliceRequestId).owner, alice);
        assertEq(vault.getRequestDetails(bobRequestId).owner, bob);
    }

    /*//////////////////////////////////////////////////////////////
                            OWNER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_updateYieldDistributor() public {
        address newDistributor = makeAddr("newDistributor");

        vm.prank(owner);
        vault.updateYieldDistributor(newDistributor);

        assertEq(vault.yieldDistributor(), newDistributor);
    }

    function test_updateCooldownDuration() public {
        vm.prank(owner);
        vault.updateCooldownDuration(14 days);

        assertEq(vault.cooldownDuration(), 14 days);
    }

    function test_updateCooldownDuration_revert_belowMin() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(StakingVault.InvalidCooldownDuration.selector, 12 hours, 1 days, 30 days)
        );
        vault.updateCooldownDuration(12 hours);
    }

    function test_updateCooldownDuration_revert_aboveMax() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.InvalidCooldownDuration.selector, 31 days, 1 days, 30 days));
        vault.updateCooldownDuration(31 days);
    }

    function test_updateCooldownEnabled() public {
        vm.prank(owner);
        vault.updateCooldownEnabled(false);

        assertFalse(vault.cooldownEnabled());
    }

    function test_updateInstantWithdrawWhitelist() public {
        vm.prank(owner);
        vault.updateInstantWithdrawWhitelist(alice, true);

        assertTrue(vault.instantWithdrawWhitelist(alice));
    }

    function test_updateInstantWithdrawWhitelist_revert_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(StakingVault.ZeroAddress.selector);
        vault.updateInstantWithdrawWhitelist(address(0), true);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_getActiveRequestIds() public {
        vm.startPrank(alice);
        vusd.approve(address(vault), 100 * UNIT);
        vault.deposit(100 * UNIT, alice);
        vault.requestRedeem(30 * UNIT, alice);
        vault.requestRedeem(20 * UNIT, alice);
        vm.stopPrank();

        uint256[] memory activeIds = vault.getActiveRequestIds(alice);
        assertEq(activeIds.length, 2);
    }

    function test_getClaimableRequests() public {
        vm.startPrank(alice);
        vusd.approve(address(vault), 100 * UNIT);
        vault.deposit(100 * UNIT, alice);
        vault.requestRedeem(30 * UNIT, alice);
        vault.requestRedeem(20 * UNIT, alice);
        vm.stopPrank();

        // Before cooldown
        (uint256[] memory claimableIds,) = vault.getClaimableRequests(alice);
        assertEq(claimableIds.length, 0);

        // After cooldown
        vm.warp(block.timestamp + 7 days);
        (claimableIds,) = vault.getClaimableRequests(alice);
        assertEq(claimableIds.length, 2);
    }

    function test_getPendingRequests() public {
        vm.startPrank(alice);
        vusd.approve(address(vault), 100 * UNIT);
        vault.deposit(100 * UNIT, alice);
        vault.requestRedeem(30 * UNIT, alice);
        vault.requestRedeem(20 * UNIT, alice);
        vm.stopPrank();

        (uint256[] memory pendingIds, uint256[] memory assets,) = vault.getPendingRequests(alice);
        assertEq(pendingIds.length, 2);
        assertEq(assets[0], 30 * UNIT);
        assertEq(assets[1], 20 * UNIT);
    }

    /*//////////////////////////////////////////////////////////////
                          TOTAL ASSETS CALCULATION
    //////////////////////////////////////////////////////////////*/

    function test_totalAssets_excludesCooldown() public {
        vm.startPrank(alice);
        vusd.approve(address(vault), 100 * UNIT);
        vault.deposit(100 * UNIT, alice);
        vm.stopPrank();

        assertEq(vault.totalAssets(), 100 * UNIT);

        vm.prank(alice);
        vault.requestRedeem(30 * UNIT, alice);

        // totalAssets should exclude cooldown assets
        assertEq(vault.totalAssets(), 70 * UNIT);
        assertEq(vault.totalAssetsInCooldown(), 30 * UNIT);
    }

    /*//////////////////////////////////////////////////////////////
                          YIELD DISTRIBUTION
    //////////////////////////////////////////////////////////////*/

    function test_yieldDistribution_increasesShareValue() public {
        // Alice deposits
        vm.startPrank(alice);
        vusd.approve(address(vault), 100 * UNIT);
        vault.deposit(100 * UNIT, alice);
        vm.stopPrank();

        // Distribute yield
        deal(address(vusd), owner, 10 * UNIT);
        vm.startPrank(owner);
        vusd.approve(address(yieldDistributor), 10 * UNIT);
        yieldDistributor.distribute(10 * UNIT);
        vm.stopPrank();

        // Fast forward to fully distribute yield
        vm.warp(block.timestamp + 7 days);

        // Bob deposits - should get fewer shares for same assets
        vm.startPrank(bob);
        vusd.approve(address(vault), 100 * UNIT);
        uint256 bobShares = vault.deposit(100 * UNIT, bob);
        vm.stopPrank();

        // Alice has 100 shares, Bob has fewer due to yield
        assertEq(vault.balanceOf(alice), 100 * UNIT);
        assertLt(bobShares, 100 * UNIT);
    }

    /*//////////////////////////////////////////////////////////////
                              FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_deposit(uint256 amount) public {
        amount = bound(amount, 1, 1000 * UNIT);

        deal(address(vusd), alice, amount);

        vm.startPrank(alice);
        vusd.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.totalAssets(), amount);
        assertGe(shares, 1); // At least 1 share minted
    }

    function testFuzz_mint(uint256 shares) public {
        shares = bound(shares, 1, 1000 * UNIT);

        // Give alice enough assets
        deal(address(vusd), alice, shares * 2);

        vm.startPrank(alice);
        vusd.approve(address(vault), shares * 2);
        uint256 assets = vault.mint(shares, alice);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), shares);
        assertGe(assets, 1); // At least 1 asset spent
    }

    function testFuzz_requestRedeem(uint256 depositAmount, uint256 redeemShares) public {
        depositAmount = bound(depositAmount, 2, 1000 * UNIT);
        redeemShares = bound(redeemShares, 1, depositAmount);

        deal(address(vusd), alice, depositAmount);

        vm.startPrank(alice);
        vusd.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);

        uint256 sharesBefore = vault.balanceOf(alice);
        (uint256 requestId, uint256 assets) = vault.requestRedeem(redeemShares, alice);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), sharesBefore - redeemShares);
        assertEq(vault.totalAssetsInCooldown(), assets);
        assertEq(vault.nextRequestId(), requestId + 1);

        IStakingVault.CooldownRequest memory request = vault.getRequestDetails(requestId);
        assertEq(request.owner, alice);
        assertEq(request.assets, assets);
    }

    function testFuzz_requestWithdraw(uint256 depositAmount, uint256 withdrawAssets) public {
        depositAmount = bound(depositAmount, 2, 1000 * UNIT);
        withdrawAssets = bound(withdrawAssets, 1, depositAmount);

        deal(address(vusd), alice, depositAmount);

        vm.startPrank(alice);
        vusd.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);

        uint256 sharesBefore = vault.balanceOf(alice);
        (uint256 requestId, uint256 shares) = vault.requestWithdraw(withdrawAssets, alice);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), sharesBefore - shares);
        assertGe(vault.totalAssetsInCooldown(), withdrawAssets);
        assertEq(vault.nextRequestId(), requestId + 1);
    }

    function testFuzz_claimWithdraw(uint256 depositAmount, uint256 redeemShares, uint256 timeElapsed) public {
        depositAmount = bound(depositAmount, 2, 1000 * UNIT);
        redeemShares = bound(redeemShares, 1, depositAmount);
        timeElapsed = bound(timeElapsed, 7 days, 365 days);

        deal(address(vusd), alice, depositAmount);

        vm.startPrank(alice);
        vusd.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        (uint256 requestId, uint256 expectedAssets) = vault.requestRedeem(redeemShares, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + timeElapsed);

        uint256 balanceBefore = vusd.balanceOf(alice);
        vm.prank(alice);
        uint256 assets = vault.claimWithdraw(requestId, alice);

        assertEq(assets, expectedAssets);
        assertEq(vusd.balanceOf(alice), balanceBefore + assets);
        assertEq(vault.totalAssetsInCooldown(), 0);
    }

    function testFuzz_cancelWithdraw(uint256 depositAmount, uint256 redeemShares) public {
        // Bound to reasonable amounts to avoid rounding issues
        depositAmount = bound(depositAmount, 1000, 1000 * UNIT);
        redeemShares = bound(redeemShares, 100, depositAmount / 2);

        deal(address(vusd), alice, depositAmount);

        vm.startPrank(alice);
        vusd.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);

        uint256 aliceShares = vault.balanceOf(alice);
        // Ensure we have enough shares
        vm.assume(aliceShares >= redeemShares);
        vm.assume(redeemShares > 0);

        (uint256 requestId, uint256 lockedAssets) = vault.requestRedeem(redeemShares, alice);
        vm.assume(lockedAssets > 0);

        uint256 sharesBefore = vault.balanceOf(alice);
        uint256 shares = vault.cancelWithdraw(requestId);
        vm.stopPrank();

        assertGe(shares, 1);
        assertEq(vault.balanceOf(alice), sharesBefore + shares);
        assertEq(vault.totalAssetsInCooldown(), 0);

        // Request should be deleted
        IStakingVault.CooldownRequest memory request = vault.getRequestDetails(requestId);
        assertEq(request.owner, address(0));
        assertEq(request.assets, 0);
    }

    function testFuzz_multipleRequests(uint256 depositAmount, uint8 numRequests) public {
        depositAmount = bound(depositAmount, 10, 1000 * UNIT);
        numRequests = uint8(bound(numRequests, 1, 10));

        deal(address(vusd), alice, depositAmount);

        vm.startPrank(alice);
        vusd.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);

        uint256 sharePerRequest = vault.balanceOf(alice) / numRequests;
        if (sharePerRequest == 0) return; // Skip if too small

        uint256 totalAssetsLocked = 0;
        for (uint256 i = 0; i < numRequests; i++) {
            (, uint256 assets) = vault.requestRedeem(sharePerRequest, alice);
            totalAssetsLocked += assets;
        }
        vm.stopPrank();

        assertEq(vault.nextRequestId(), numRequests);
        assertEq(vault.totalAssetsInCooldown(), totalAssetsLocked);
        assertEq(vault.getActiveRequestIds(alice).length, numRequests);
    }

    function testFuzz_instantWithdraw_whenWhitelisted(uint256 depositAmount, uint256 withdrawAmount) public {
        depositAmount = bound(depositAmount, 2, 1000 * UNIT);
        withdrawAmount = bound(withdrawAmount, 1, depositAmount);

        vm.prank(owner);
        vault.updateInstantWithdrawWhitelist(alice, true);

        deal(address(vusd), alice, depositAmount);

        vm.startPrank(alice);
        vusd.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);

        uint256 balanceBefore = vusd.balanceOf(alice);
        vault.withdraw(withdrawAmount, alice, alice);
        vm.stopPrank();

        assertEq(vusd.balanceOf(alice), balanceBefore + withdrawAmount);
    }

    function testFuzz_cooldownDuration(uint256 duration, uint256 depositAmount) public {
        duration = bound(duration, 1 days, 30 days); // MIN_COOLDOWN_DURATION to MAX_COOLDOWN_DURATION
        depositAmount = bound(depositAmount, 2, 1000 * UNIT);

        vm.prank(owner);
        vault.updateCooldownDuration(duration);

        deal(address(vusd), alice, depositAmount);

        vm.startPrank(alice);
        vusd.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        (uint256 requestId,) = vault.requestRedeem(depositAmount / 2, alice);
        vm.stopPrank();

        IStakingVault.CooldownRequest memory request = vault.getRequestDetails(requestId);
        assertEq(request.claimableAt, block.timestamp + duration);
    }

    function testFuzz_shareValue_afterYield(uint256 depositAmount, uint256 yieldAmount) public {
        depositAmount = bound(depositAmount, 1000, 1000 * UNIT);
        yieldAmount = bound(yieldAmount, 100, depositAmount / 10);
        if (yieldAmount == 0) return;

        // Alice deposits
        deal(address(vusd), alice, depositAmount);
        vm.startPrank(alice);
        vusd.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        uint256 aliceShares = vault.balanceOf(alice);

        // Distribute yield
        deal(address(vusd), owner, yieldAmount);
        vm.startPrank(owner);
        vusd.approve(address(yieldDistributor), yieldAmount);
        yieldDistributor.distribute(yieldAmount);
        vm.stopPrank();

        // Fast forward
        vm.warp(block.timestamp + 7 days);

        // Bob deposits same amount
        deal(address(vusd), bob, depositAmount);
        vm.startPrank(bob);
        vusd.approve(address(vault), depositAmount);
        uint256 bobShares = vault.deposit(depositAmount, bob);
        vm.stopPrank();

        // Alice should have more or equal shares than Bob for same deposit (yield increases share price)
        assertGe(aliceShares, bobShares);
    }

    function test_getClaimableRequests_arrayLengthReduction() public {
        // Setup: Alice deposits and creates multiple requests
        uint256 depositAmount = 1000e18;
        deal(address(vusd), alice, depositAmount);
        vm.startPrank(alice);
        vusd.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);

        // Create 3 requests
        vault.requestRedeem(100e18, alice);
        vault.requestRedeem(200e18, alice);
        vault.requestRedeem(300e18, alice);
        vm.stopPrank();

        // Verify 3 active requests
        uint256[] memory activeIds = vault.getActiveRequestIds(alice);
        assertEq(activeIds.length, 3, "Should have 3 active requests");

        // Before cooldown: 0 claimable, 3 pending
        (uint256[] memory claimableIds, uint256[] memory claimableAssets) = vault.getClaimableRequests(alice);
        (uint256[] memory pendingIds, uint256[] memory pendingAssets, uint256[] memory pendingClaimableAt) =
            vault.getPendingRequests(alice);

        assertEq(claimableIds.length, 0, "Claimable array should be empty");
        assertEq(claimableAssets.length, 0, "Claimable assets array should be empty");
        assertEq(pendingIds.length, 3, "Pending array should have 3 items");
        assertEq(pendingAssets.length, 3, "Pending assets array should have 3 items");
        assertEq(pendingClaimableAt.length, 3, "Pending claimableAt array should have 3 items");

        // Fast forward past cooldown
        vm.warp(block.timestamp + vault.cooldownDuration() + 1);

        // After cooldown: 3 claimable, 0 pending
        (claimableIds, claimableAssets) = vault.getClaimableRequests(alice);
        (pendingIds, pendingAssets, pendingClaimableAt) = vault.getPendingRequests(alice);

        assertEq(claimableIds.length, 3, "Claimable array should have 3 items");
        assertEq(claimableAssets.length, 3, "Claimable assets array should have 3 items");
        assertEq(pendingIds.length, 0, "Pending array should be empty");
        assertEq(pendingAssets.length, 0, "Pending assets array should be empty");
        assertEq(pendingClaimableAt.length, 0, "Pending claimableAt array should be empty");

        // Claim one request - now 2 claimable
        vm.prank(alice);
        vault.claimWithdraw(claimableIds[0], alice);

        (claimableIds, claimableAssets) = vault.getClaimableRequests(alice);
        assertEq(claimableIds.length, 2, "Claimable array should have 2 items after claim");
        assertEq(claimableAssets.length, 2, "Claimable assets array should have 2 items after claim");
    }
}
