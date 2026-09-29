// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Gateway} from "src/Gateway.sol";
import {Treasury} from "src/Treasury.sol";
import {PeggedToken} from "src/PeggedToken.sol";
import {StakingVault} from "src/StakingVault.sol";
import {YieldDistributor} from "src/YieldDistributor.sol";
import {YieldManager} from "src/YieldManager.sol";
import {IPeggedToken} from "src/interfaces/IPeggedToken.sol";
import {IYieldDistributor} from "src/interfaces/IYieldDistributor.sol";
import {MockChainlinkOracle} from "test/mocks/MockChainlinkOracle.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockYieldVault} from "test/mocks/MockYieldVault.sol";
import {MockNonPullingYieldDistributor} from "test/mocks/MockNonPullingYieldDistributor.sol";

contract YieldManagerTest is Test {
    using SafeERC20 for IERC20;

    PeggedToken peggedToken;
    Gateway gateway;
    Treasury treasury;
    StakingVault stakingVault;
    YieldDistributor distributor;
    YieldManager yieldManager;
    address owner;
    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address token;
    MockChainlinkOracle mockOracle;
    MockYieldVault mockVault;

    uint256 constant INITIAL_DEPOSIT = 100_000e6; // 6-decimals collateral
    // 36_500 staked at 10% APR over a 7-day period => exactly 70 per period
    uint256 constant STAKED = 36_500e18;
    uint256 constant MAX_APY_BPS = 1_500;
    uint256 constant APY_BPS = 1_000;
    uint256 constant TARGET_PER_PERIOD = 70e18;
    uint256 constant MAX_PER_PERIOD = 105e18;
    uint256 constant ABSOLUTE_CAP = 1_000e18;
    uint256 constant PERIOD = 7 days;

    event AbsoluteCapUpdated(uint256 previousCap, uint256 newCap);
    event Distributed(address indexed caller, uint256 amount, uint256 bufferLeft);
    event Harvested(address indexed token, uint256 tokenAmount, uint256 peggedTokenAmount);
    event MaxApyUpdated(uint256 previousApyBps, uint256 newApyBps);
    event Swept(address indexed token, uint256 amount, address indexed receiver);

    function setUp() public {
        owner = address(this);
        peggedToken = new PeggedToken("VUSD", "VUSD", owner);
        treasury = new Treasury(address(peggedToken), admin);
        peggedToken.updateTreasury(address(treasury));

        Gateway gatewayImpl = new Gateway();
        bytes memory gatewayInit =
            abi.encodeWithSelector(Gateway.initialize.selector, address(peggedToken), type(uint256).max, 7 days);
        gateway = Gateway(address(new ERC1967Proxy(address(gatewayImpl), gatewayInit)));
        peggedToken.updateGateway(address(gateway));

        StakingVault vaultImpl = new StakingVault();
        stakingVault = StakingVault(
            address(
                new ERC1967Proxy(
                    address(vaultImpl),
                    abi.encodeCall(StakingVault.initialize, (address(peggedToken), "Staked VUSD", "sVUSD", owner))
                )
            )
        );

        YieldDistributor distributorImpl = new YieldDistributor();
        bytes memory distributorInit = abi.encodeWithSelector(
            YieldDistributor.initialize.selector, address(peggedToken), address(stakingVault), admin
        );
        distributor = YieldDistributor(address(new ERC1967Proxy(address(distributorImpl), distributorInit)));
        stakingVault.updateYieldDistributor(address(distributor));

        yieldManager = new YieldManager(
            IPeggedToken(address(peggedToken)), IYieldDistributor(address(distributor)), MAX_APY_BPS, ABSOLUTE_CAP
        );

        token = address(new MockERC20());
        mockVault = new MockYieldVault(token);
        mockOracle = new MockChainlinkOracle(1e8);

        vm.startPrank(admin);
        treasury.addToWhitelist(token, address(mockVault), address(mockOracle), 1 hours);
        treasury.grantRole(treasury.UMM_ROLE(), address(yieldManager));
        treasury.grantRole(treasury.KEEPER_ROLE(), keeper);
        distributor.grantRole(distributor.DISTRIBUTOR_ROLE(), address(yieldManager));
        vm.stopPrank();

        // Seed backed supply: alice mints pegged tokens by depositing collateral
        deal(token, alice, INITIAL_DEPOSIT);
        vm.startPrank(alice);
        IERC20(token).forceApprove(address(gateway), INITIAL_DEPOSIT);
        gateway.deposit(token, INITIAL_DEPOSIT, 0, alice);
        IERC20(address(peggedToken)).forceApprove(address(stakingVault), STAKED);
        stakingVault.deposit(STAKED, alice);
        vm.stopPrank();
    }

    /// @dev Simulates yield by donating collateral to the treasury (loose balance counts in reserve)
    function createExcess(uint256 tokenAmount) internal {
        deal(token, address(this), tokenAmount);
        IERC20(token).safeTransfer(address(treasury), tokenAmount);
    }

    function fillBuffer(uint256 tokenAmount) internal {
        createExcess(tokenAmount);
        vm.prank(keeper);
        yieldManager.harvest(token, 0);
    }

    function distributeAt(uint256 apyBps) internal returns (uint256 amount) {
        amount = yieldManager.amountForApy(apyBps);
        if (amount > 0) yieldManager.distribute(amount);
    }

    function dripLeft() internal view returns (uint256) {
        uint256 _finish = distributor.periodFinish();
        if (block.timestamp >= _finish) return 0;
        return ((_finish - block.timestamp) * distributor.rewardRate()) / 1e18;
    }

    function assertBackingInvariant() internal view {
        assertGe(
            treasury.reserve(), peggedToken.totalSupply() - gateway.amoSupply(), "reserve must cover backed supply"
        );
    }

    // --- constructor ---

    function test_constructor() public view {
        assertEq(address(yieldManager.PEGGED_TOKEN()), address(peggedToken), "pegged token mismatch");
        assertEq(address(yieldManager.YIELD_DISTRIBUTOR()), address(distributor), "distributor mismatch");
        assertEq(yieldManager.maxApyBps(), MAX_APY_BPS, "max apy mismatch");
        assertEq(yieldManager.absoluteCap(), ABSOLUTE_CAP, "cap mismatch");
    }

    function test_constructor_revertIfAddressIsZero() public {
        vm.expectRevert(YieldManager.AddressIsZero.selector);
        new YieldManager(IPeggedToken(address(0)), IYieldDistributor(address(distributor)), 0, 1);

        vm.expectRevert(YieldManager.AddressIsZero.selector);
        new YieldManager(IPeggedToken(address(peggedToken)), IYieldDistributor(address(0)), 0, 1);
    }

    function test_constructor_revertIfAssetMismatch() public {
        YieldDistributor otherImpl = new YieldDistributor();
        bytes memory otherInit =
            abi.encodeWithSelector(YieldDistributor.initialize.selector, token, address(stakingVault), admin);
        YieldDistributor otherDistributor = YieldDistributor(address(new ERC1967Proxy(address(otherImpl), otherInit)));

        vm.expectRevert(YieldManager.AssetMismatch.selector);
        new YieldManager(IPeggedToken(address(peggedToken)), IYieldDistributor(address(otherDistributor)), 0, 1);
    }

    function test_constructor_revertIfMaxApyTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(YieldManager.MaxApyTooHigh.selector, 5_001, 5_000));
        new YieldManager(IPeggedToken(address(peggedToken)), IYieldDistributor(address(distributor)), 5_001, 1);
    }

    function test_constructor_revertIfAbsoluteCapIsZero() public {
        vm.expectRevert(YieldManager.AbsoluteCapIsZero.selector);
        new YieldManager(IPeggedToken(address(peggedToken)), IYieldDistributor(address(distributor)), 0, 0);
    }

    // --- distribute ---

    function test_distribute() public {
        fillBuffer(1_000e6);
        assertEq(yieldManager.amountForApy(APY_BPS), TARGET_PER_PERIOD, "preview mismatch");

        vm.expectEmit();
        emit Distributed(keeper, TARGET_PER_PERIOD, 1_000e18 - TARGET_PER_PERIOD);
        vm.prank(keeper);
        yieldManager.distribute(TARGET_PER_PERIOD);

        assertEq(yieldManager.buffer(), 1_000e18 - TARGET_PER_PERIOD, "rest stays buffered");
        assertEq(peggedToken.balanceOf(address(distributor)), TARGET_PER_PERIOD, "distributor funded");
        assertApproxEqAbs(dripLeft(), TARGET_PER_PERIOD, 2, "distributor drips the amount over the period");
        assertApproxEqAbs(yieldManager.currentApyBps(), APY_BPS, 1, "drips at the target APR");
    }

    function test_distribute_upToMaxApy() public {
        fillBuffer(1_000e6);
        assertEq(yieldManager.maxDistribute(), MAX_PER_PERIOD, "headroom is one period at max APR");

        yieldManager.distribute(MAX_PER_PERIOD);

        assertEq(yieldManager.maxDistribute(), 0, "no headroom left");
    }

    function test_distribute_upToAbsoluteCap() public {
        fillBuffer(1_000e6);
        vm.prank(admin);
        yieldManager.setAbsoluteCap(20e18);
        assertEq(yieldManager.maxDistribute(), 20e18, "cap should bind the headroom");

        vm.expectPartialRevert(YieldManager.DripExceedsCap.selector);
        yieldManager.distribute(21e18);

        yieldManager.distribute(20e18);
        assertApproxEqAbs(dripLeft(), 20e18, 2, "drip at the cap");
    }

    function test_distribute_revertIfAboveMaxApy() public {
        fillBuffer(1_000e6);
        vm.expectPartialRevert(YieldManager.DripExceedsCap.selector);
        yieldManager.distribute(MAX_PER_PERIOD + 1e18);
    }

    function test_distribute_revertIfInsufficientBuffer() public {
        fillBuffer(5e6);
        assertEq(yieldManager.amountForApy(APY_BPS), 5e18, "preview limited by the buffer");
        vm.expectRevert(abi.encodeWithSelector(YieldManager.InsufficientBuffer.selector, 5e18 + 1, 5e18));
        yieldManager.distribute(5e18 + 1);
    }

    function test_distribute_revertIfEmptyVault() public {
        fillBuffer(1_000e6);
        uint256 shares = stakingVault.balanceOf(alice);
        vm.prank(alice);
        stakingVault.requestRedeem(shares, alice);
        assertEq(stakingVault.totalAssets(), 0, "no assets earning");

        assertEq(yieldManager.amountForApy(APY_BPS), 0, "no stakers, no yield");
        vm.expectPartialRevert(YieldManager.DripExceedsCap.selector);
        yieldManager.distribute(1e18);
    }

    function test_distribute_revertIfNoSharesWithAssets() public {
        fillBuffer(1_000e6);
        uint256 shares = stakingVault.balanceOf(alice);
        vm.prank(alice);
        stakingVault.requestRedeem(shares, alice);
        // A donation leaves assets in a vault with no shares to earn them
        vm.prank(alice);
        IERC20(address(peggedToken)).safeTransfer(address(stakingVault), 10_000e18);
        assertGt(stakingVault.totalAssets(), 0, "assets without shares");

        assertEq(yieldManager.maxDistribute(), 0, "must not feed a drip nobody earns");
        vm.expectPartialRevert(YieldManager.DripExceedsCap.selector);
        yieldManager.distribute(1e18);
    }

    function test_distribute_revertIfMaxApyIsZero() public {
        fillBuffer(1_000e6);
        vm.prank(admin);
        yieldManager.setMaxApy(0);

        assertEq(yieldManager.maxDistribute(), 0, "zero max APR pauses distribution");
        vm.expectPartialRevert(YieldManager.DripExceedsCap.selector);
        yieldManager.distribute(1e18);
    }

    function test_distribute_repeatCallsCannotStackPastCap() public {
        fillBuffer(1_000e6);
        yieldManager.distribute(MAX_PER_PERIOD);

        vm.expectPartialRevert(YieldManager.DripExceedsCap.selector);
        yieldManager.distribute(1e18);

        skip(1 days);
        uint256 topUp = yieldManager.maxDistribute();
        // ~1 day of drip consumed; accrued yield nudges the cap up slightly
        assertApproxEqRel(topUp, MAX_PER_PERIOD / 7, 0.01e18, "headroom is ~one day of drip");
        yieldManager.distribute(topUp);
    }

    function test_distribute_keeperDepositCannotPassAbsoluteCap() public {
        fillBuffer(10_000e6);
        vm.prank(admin);
        yieldManager.setAbsoluteCap(150e18);
        // A keeper-timed deposit doubles spot totalAssets right before the call
        deal(address(peggedToken), bob, STAKED);
        vm.startPrank(bob);
        IERC20(address(peggedToken)).forceApprove(address(stakingVault), STAKED);
        stakingVault.deposit(STAKED, bob);
        vm.stopPrank();
        assertEq(yieldManager.maxDistribute(), 150e18, "cap binds the inflated APR headroom");

        vm.expectPartialRevert(YieldManager.DripExceedsCap.selector);
        yieldManager.distribute(2 * MAX_PER_PERIOD);
    }

    function test_distribute_lateKeeperNoCatchUp() public {
        fillBuffer(1_000e6);
        distributeAt(APY_BPS);

        skip(3 * PERIOD);
        uint256 topUp = distributeAt(APY_BPS);

        assertApproxEqRel(topUp, TARGET_PER_PERIOD, 0.01e18, "no catch-up for missed periods");
        assertApproxEqAbs(dripLeft(), topUp, 2, "drip equals one period of target");
    }

    function test_distribute_followsTvl() public {
        fillBuffer(1_000e6);
        distributeAt(APY_BPS);

        vm.startPrank(alice);
        IERC20(address(peggedToken)).safeTransfer(bob, STAKED);
        vm.stopPrank();
        vm.startPrank(bob);
        IERC20(address(peggedToken)).forceApprove(address(stakingVault), STAKED);
        stakingVault.deposit(STAKED, bob);
        vm.stopPrank();
        assertApproxEqAbs(yieldManager.currentApyBps(), APY_BPS / 2, 1, "deposit dilutes the APR");

        uint256 topUp = distributeAt(APY_BPS);

        assertApproxEqAbs(topUp, TARGET_PER_PERIOD, 1e6, "doubled TVL doubles the target");
        assertApproxEqAbs(dripLeft(), 2 * TARGET_PER_PERIOD, 1e6, "drip at the doubled target");
    }

    function test_distribute_loweredMaxApyBlocksUntilDripFalls() public {
        fillBuffer(1_000e6);
        distributeAt(APY_BPS);

        vm.prank(admin);
        yieldManager.setMaxApy(APY_BPS / 2);

        skip(1 days);
        assertEq(yieldManager.maxDistribute(), 0, "drip still above the lowered cap");

        skip(3 days); // remaining drip ~30 < new cap ~35
        assertGt(yieldManager.maxDistribute(), 0, "headroom once the drip falls under the cap");
    }

    function test_distribute_matchesDistributorRollover() public {
        fillBuffer(1_000e6);
        distributeAt(APY_BPS);
        skip(2 days);

        uint256 rolled = yieldManager.undistributed();
        uint256 topUp = distributeAt(APY_BPS);
        assertApproxEqAbs(dripLeft(), rolled + topUp, 2, "distributor rolled over undistributed + top-up");
    }

    function test_distribute_absoluteCapIsWeeklyWhateverDuration() public {
        fillBuffer(1_000e6);
        vm.prank(admin);
        yieldManager.setAbsoluteCap(70e18);
        vm.prank(admin);
        distributor.updateYieldDuration(1 days);

        // 70/week scales to 10/day, under the 15/day the max APR allows
        assertEq(yieldManager.maxDistribute(), 10e18, "cap scaled to the 1-day period");
        vm.expectPartialRevert(YieldManager.DripExceedsCap.selector);
        yieldManager.distribute(11e18);
    }

    function test_distribute_maxApyIsDurationInvariant() public {
        fillBuffer(1_000e6);
        vm.prank(admin);
        distributor.updateYieldDuration(1 days);

        assertEq(yieldManager.maxDistribute(), MAX_PER_PERIOD / 7, "one day at the max APR");
    }

    function test_distribute_weeklyOutflowBoundedWithShortDuration() public {
        fillBuffer(10_000e6);
        vm.prank(admin);
        yieldManager.setAbsoluteCap(70e18);
        vm.prank(admin);
        distributor.updateYieldDuration(1 days);

        uint256 bufferBefore = yieldManager.buffer();
        for (uint256 i; i < 7 * 24; ++i) {
            uint256 amount = yieldManager.maxDistribute();
            if (amount > 0) yieldManager.distribute(amount);
            skip(1 hours);
        }

        // Pays at most the weekly cap, plus at most one 1-day period pre-funded
        assertLe(bufferBefore - yieldManager.buffer(), 70e18 + 10e18 + 1e6, "weekly outflow above the cap");
    }

    function test_distribute_revertIfZeroAmount() public {
        fillBuffer(1_000e6);
        vm.expectRevert(YieldManager.AmountIsZero.selector);
        yieldManager.distribute(0);
    }

    function test_distribute_exitsRaiseApyAboveMaxUntilDripFalls() public {
        fillBuffer(1_000e6);
        yieldManager.distribute(MAX_PER_PERIOD);

        // Half the stake exits: the fixed drip now pays the rest double the max APR
        uint256 shares = stakingVault.balanceOf(alice);
        vm.prank(alice);
        stakingVault.requestRedeem(shares / 2, alice);
        assertApproxEqAbs(yieldManager.currentApyBps(), 2 * MAX_APY_BPS, 2, "exit raises the APR");
        assertEq(yieldManager.maxDistribute(), 0, "no top-up while above the cap");

        skip(4 days); // remaining drip ~45 < new cap ~52.5
        assertGt(yieldManager.maxDistribute(), 0, "headroom once the drip falls under the cap");
    }

    function test_distribute_shortAmountLowersCurrentApy() public {
        fillBuffer(1_000e6);
        distributeAt(APY_BPS);
        skip(6 days);

        // Stretching the last day of drip plus a small amount over a fresh period lowers the rate
        yieldManager.distribute(1e18);
        assertLt(yieldManager.currentApyBps(), APY_BPS / 2, "short amount lowers the current APR");
    }

    function test_distribute_revertIfInsufficientBufferBeforeCap() public {
        fillBuffer(5e6);
        vm.expectRevert(abi.encodeWithSelector(YieldManager.InsufficientBuffer.selector, 1_000e18, 5e18));
        yieldManager.distribute(1_000e18);
    }

    function test_distribute_donationCountsAsBuffer() public {
        deal(address(peggedToken), address(this), 50e18);
        IERC20(address(peggedToken)).safeTransfer(address(yieldManager), 50e18);

        assertEq(yieldManager.buffer(), 50e18, "donation is buffer");
        yieldManager.distribute(50e18);
        assertEq(yieldManager.buffer(), 0, "donation distributed");
    }

    function test_distribute_revertIfNotKeeper() public {
        fillBuffer(1_000e6);
        bytes32 keeperRole = yieldManager.KEEPER_ROLE();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(YieldManager.AccessControlUnauthorizedAccount.selector, bob, keeperRole));
        yieldManager.distribute(1e18);
    }

    function test_distribute_revertIfDistributorOvershoots() public {
        // Without pulling first, accrued yield is re-dripped on top of the top-up
        MockNonPullingYieldDistributor legacyImpl = new MockNonPullingYieldDistributor();
        MockNonPullingYieldDistributor legacy = MockNonPullingYieldDistributor(
            address(
                new ERC1967Proxy(
                    address(legacyImpl),
                    abi.encodeCall(
                        MockNonPullingYieldDistributor.initialize, (address(peggedToken), address(stakingVault), admin)
                    )
                )
            )
        );
        stakingVault.updateYieldDistributor(address(legacy));
        YieldManager legacyManager = new YieldManager(
            IPeggedToken(address(peggedToken)), IYieldDistributor(address(legacy)), MAX_APY_BPS, ABSOLUTE_CAP
        );
        vm.startPrank(admin);
        treasury.grantRole(treasury.UMM_ROLE(), address(legacyManager));
        legacy.grantRole(legacy.DISTRIBUTOR_ROLE(), address(legacyManager));
        vm.stopPrank();

        createExcess(1_000e6);
        vm.prank(keeper);
        legacyManager.harvestAndDistribute(token, 0, MAX_PER_PERIOD);

        skip(3 days); // accrued yield sits unpulled in the distributor
        uint256 headroom = legacyManager.maxDistribute();
        vm.prank(keeper);
        vm.expectPartialRevert(YieldManager.DripExceedsCap.selector);
        legacyManager.distribute(headroom);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_distribute_dripNeverExceedsCap(uint32[5] memory gaps_, uint96[5] memory amounts_) public {
        fillBuffer(10_000e6);
        for (uint256 i; i < gaps_.length; ++i) {
            skip(bound(gaps_[i], 0, 2 * PERIOD));
            uint256 headroom = yieldManager.maxDistribute();
            uint256 cap = stakingVault.totalAssets() * MAX_APY_BPS * PERIOD / (10_000 * 365 days);
            uint256 amount = bound(amounts_[i], 1, 2 * MAX_PER_PERIOD);
            try yieldManager.distribute(amount) {
                assertLe(amount, headroom + 2, "accepted more than the headroom");
                assertLe(dripLeft(), cap, "drip must not exceed one period at max APR");
            } catch {
                assertGt(amount, headroom, "rejected an amount within the headroom");
            }
        }
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_distribute_amountForApyHitsTarget(uint32[5] memory gaps_, uint16[5] memory apys_) public {
        fillBuffer(10_000e6);
        for (uint256 i; i < gaps_.length; ++i) {
            skip(bound(gaps_[i], 0, 2 * PERIOD));
            uint256 apyBps = bound(apys_[i], 1, MAX_APY_BPS);
            if (distributeAt(apyBps) > 0) {
                assertLe(yieldManager.currentApyBps(), apyBps, "drip must not exceed the target");
                assertApproxEqAbs(yieldManager.currentApyBps(), apyBps, 1, "drip must sit at target");
            }
        }
    }

    // --- harvest ---

    function test_harvest() public {
        createExcess(1_000e6);
        assertEq(yieldManager.harvestable(), 1_000e18, "harvestable should equal donated excess");

        vm.expectEmit();
        emit Harvested(token, 1_000e6, 1_000e18);
        vm.prank(keeper);
        uint256 minted = yieldManager.harvest(token, 1_000e18);

        assertEq(minted, 1_000e18, "minted amount mismatch");
        assertEq(yieldManager.buffer(), 1_000e18, "harvest should fill the buffer");
        assertEq(peggedToken.balanceOf(address(distributor)), 0, "harvest must not distribute");
        assertEq(IERC20(token).balanceOf(address(yieldManager)), 0, "yieldManager must hold no collateral");
        assertEq(yieldManager.harvestable(), 0, "excess should be fully harvested");
        assertBackingInvariant();
    }

    function test_harvest_nothingToHarvest() public {
        vm.recordLogs();
        vm.prank(keeper);
        uint256 minted = yieldManager.harvest(token, 0);

        assertEq(minted, 0, "nothing to harvest");
        assertEq(vm.getRecordedLogs().length, 0, "no-op harvest must not emit");
    }

    function test_harvest_excessInVault() public {
        // Push the donated excess into the yield vault to exercise harvest's vault-withdraw leg
        createExcess(1_000e6);
        treasury.push(token, 1_000e6);
        assertEq(IERC20(token).balanceOf(address(treasury)), 0, "excess should sit in the vault");

        vm.prank(keeper);
        uint256 minted = yieldManager.harvest(token, 1_000e18);

        assertEq(minted, 1_000e18, "minted amount mismatch");
        assertBackingInvariant();
    }

    function test_harvest_withMintFee() public {
        gateway.updateMintFee(token, 50); // 0.5%
        createExcess(1_000e6);

        vm.prank(keeper);
        uint256 minted = yieldManager.harvest(token, 995e18);

        assertEq(minted, 995e18, "minted should be net of mint fee");
        // The fee remainder stays in the treasury as excess for the next cycle
        assertEq(yieldManager.harvestable(), 5e18, "fee remainder should stay harvestable");
        assertBackingInvariant();
    }

    function test_harvest_priceBelowParWithinTolerance() public {
        mockOracle.updatePrice(0.995e8); // 0.5% below par, within the treasury's 1% priceTolerance
        createExcess(1_000e6);

        // Repricing shrinks the whole reserve: excess = 101_000 * 0.995 - 100_000 = 495 pegged.
        // Harvest converts it back to ~497.49 tokens, which mint at price (pegBand = 0 => below pegFloor).
        vm.prank(keeper);
        uint256 minted = yieldManager.harvest(token, 0);

        assertApproxEqAbs(minted, 495e18, 1e12, "minted should be valued at price");
        assertBackingInvariant();
    }

    function test_harvest_revertIfPriceExceedsTolerance() public {
        createExcess(1_000e6);
        mockOracle.updatePrice(0.98e8); // 2% below par, beyond the treasury's 1% priceTolerance

        // The treasury-level depeg circuit-breaker fires inside harvest's getPrice call
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Treasury.PriceExceedTolerance.selector, 0.98e8, 1.01e8, 0.99e8));
        yieldManager.harvest(token, 0);
    }

    function test_harvest_revertIfMinOutTooHigh() public {
        createExcess(1_000e6);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Gateway.MintableIsLessThanMinimum.selector, 1_000e18, 1_000e18 + 1));
        yieldManager.harvest(token, 1_000e18 + 1);
    }

    function test_harvest_revertIfNotKeeper() public {
        bytes32 keeperRole = yieldManager.KEEPER_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(YieldManager.AccessControlUnauthorizedAccount.selector, alice, keeperRole)
        );
        yieldManager.harvest(token, 0);
    }

    // --- harvestAndDistribute ---

    function test_harvestAndDistribute() public {
        createExcess(1_000e6);

        vm.prank(keeper);
        uint256 minted = yieldManager.harvestAndDistribute(token, 1_000e18, TARGET_PER_PERIOD);

        assertEq(minted, 1_000e18, "minted mismatch");
        assertEq(yieldManager.buffer(), 1_000e18 - TARGET_PER_PERIOD, "rest stays buffered");
        assertBackingInvariant();
    }

    function test_harvestAndDistribute_distributesBufferWithoutExcess() public {
        fillBuffer(1_000e6);

        vm.prank(keeper);
        uint256 minted = yieldManager.harvestAndDistribute(token, 0, TARGET_PER_PERIOD);

        assertEq(minted, 0, "nothing to harvest");
        assertEq(yieldManager.buffer(), 1_000e18 - TARGET_PER_PERIOD, "buffer still pays out");
    }

    function test_harvestAndDistribute_revertIfAboveCapRollsBackHarvest() public {
        createExcess(1_000e6);

        vm.prank(keeper);
        vm.expectPartialRevert(YieldManager.DripExceedsCap.selector);
        yieldManager.harvestAndDistribute(token, 0, MAX_PER_PERIOD + 1e18);

        assertEq(yieldManager.buffer(), 0, "harvest rolled back");
        assertEq(yieldManager.harvestable(), 1_000e18, "excess still in the treasury");
    }

    function test_harvestAndDistribute_emitsBufferLeftAfterHarvest() public {
        fillBuffer(100e6);
        createExcess(1_000e6);

        vm.expectEmit();
        emit Distributed(keeper, TARGET_PER_PERIOD, 1_100e18 - TARGET_PER_PERIOD);
        vm.prank(keeper);
        yieldManager.harvestAndDistribute(token, 0, TARGET_PER_PERIOD);
    }

    function test_harvestAndDistribute_revertIfNotKeeper() public {
        bytes32 keeperRole = yieldManager.KEEPER_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(YieldManager.AccessControlUnauthorizedAccount.selector, alice, keeperRole)
        );
        yieldManager.harvestAndDistribute(token, 0, 1e18);
    }

    function test_harvestAndDistribute_revertIfZeroAmount() public {
        createExcess(1_000e6);
        vm.prank(keeper);
        vm.expectRevert(YieldManager.AmountIsZero.selector);
        yieldManager.harvestAndDistribute(token, 0, 0);
    }

    // --- setters ---

    function test_setAbsoluteCap() public {
        vm.expectEmit();
        emit AbsoluteCapUpdated(ABSOLUTE_CAP, 20e18);
        vm.prank(admin);
        yieldManager.setAbsoluteCap(20e18);

        assertEq(yieldManager.absoluteCap(), 20e18, "cap not updated");
    }

    function test_setAbsoluteCap_revertIfZero() public {
        vm.prank(admin);
        vm.expectRevert(YieldManager.AbsoluteCapIsZero.selector);
        yieldManager.setAbsoluteCap(0);
    }

    function test_setAbsoluteCap_revertIfNotAdmin() public {
        bytes32 adminRole = yieldManager.DEFAULT_ADMIN_ROLE();
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(YieldManager.AccessControlUnauthorizedAccount.selector, keeper, adminRole)
        );
        yieldManager.setAbsoluteCap(1);
    }

    function test_setMaxApy() public {
        vm.expectEmit();
        emit MaxApyUpdated(MAX_APY_BPS, 500);
        vm.prank(admin);
        yieldManager.setMaxApy(500);

        assertEq(yieldManager.maxApyBps(), 500, "apy not updated");
        assertEq(yieldManager.maxDistribute(), 0, "no headroom above 5%");
    }

    function test_setMaxApy_atBound() public {
        uint256 bound = yieldManager.MAX_APY_BPS();
        vm.prank(admin);
        yieldManager.setMaxApy(bound);
        assertEq(yieldManager.maxApyBps(), bound, "bound accepted");
    }

    function test_setMaxApy_raiseAfterLowering() public {
        fillBuffer(1_000e6);
        vm.startPrank(admin);
        yieldManager.setMaxApy(0);
        yieldManager.setMaxApy(MAX_APY_BPS);
        vm.stopPrank();

        assertEq(yieldManager.maxDistribute(), MAX_PER_PERIOD, "headroom restored");
    }

    function test_setMaxApy_revertIfTooHigh() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(YieldManager.MaxApyTooHigh.selector, 5_001, 5_000));
        yieldManager.setMaxApy(5_001);
    }

    function test_setMaxApy_revertIfNotAdmin() public {
        bytes32 adminRole = yieldManager.DEFAULT_ADMIN_ROLE();
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(YieldManager.AccessControlUnauthorizedAccount.selector, keeper, adminRole)
        );
        yieldManager.setMaxApy(500);
    }

    // --- sweep ---

    function test_sweep() public {
        MockERC20 errant = new MockERC20();
        deal(address(errant), address(yieldManager), 123e6);

        vm.expectEmit();
        emit Swept(address(errant), 123e6, alice);
        vm.prank(admin);
        yieldManager.sweep(address(errant), alice);

        assertEq(errant.balanceOf(alice), 123e6, "sweep did not transfer");
    }

    function test_sweep_buffer() public {
        fillBuffer(1_000e6);

        vm.prank(admin);
        yieldManager.sweep(address(peggedToken), address(treasury));

        assertEq(yieldManager.buffer(), 0, "buffer swept");
        assertEq(peggedToken.balanceOf(address(treasury)), 1_000e18, "buffer moved out");
    }

    function test_sweep_revertIfNotAdmin() public {
        // owner holds KEEPER + MAINTAINER but not DEFAULT_ADMIN
        vm.expectRevert(
            abi.encodeWithSelector(
                YieldManager.AccessControlUnauthorizedAccount.selector, owner, yieldManager.DEFAULT_ADMIN_ROLE()
            )
        );
        yieldManager.sweep(token, alice);
    }

    function test_sweep_revertIfReceiverIsZero() public {
        vm.prank(admin);
        vm.expectRevert(YieldManager.AddressIsZero.selector);
        yieldManager.sweep(token, address(0));
    }

    // --- views ---

    function test_amountForApy() public {
        assertEq(yieldManager.amountForApy(APY_BPS), 0, "empty buffer");
        fillBuffer(1_000e6);
        assertEq(yieldManager.amountForApy(APY_BPS), TARGET_PER_PERIOD, "10% APR on 36_500 over 7 days");
        assertEq(yieldManager.amountForApy(5_000), 350e18, "not capped by maxApyBps");
        vm.prank(admin);
        yieldManager.setAbsoluteCap(20e18);
        assertEq(yieldManager.amountForApy(APY_BPS), TARGET_PER_PERIOD, "not capped by absoluteCap");
    }

    function test_currentApyBps() public {
        assertEq(yieldManager.currentApyBps(), 0, "nothing dripping");
        fillBuffer(1_000e6);
        distributeAt(APY_BPS);
        assertApproxEqAbs(yieldManager.currentApyBps(), APY_BPS, 1, "drips at the target");
        skip(PERIOD);
        assertEq(yieldManager.currentApyBps(), 0, "drip finished");
    }

    function test_currentApyBps_zeroWithoutShares() public {
        fillBuffer(1_000e6);
        distributeAt(APY_BPS);
        uint256 shares = stakingVault.balanceOf(alice);
        vm.prank(alice);
        stakingVault.requestRedeem(shares, alice);
        vm.prank(alice);
        IERC20(address(peggedToken)).safeTransfer(address(stakingVault), 1_000e18);

        assertEq(yieldManager.currentApyBps(), 0, "nobody earns without shares");
    }

    function test_harvestable() public {
        assertEq(yieldManager.harvestable(), 0, "no excess initially");
        createExcess(1_000e6);
        assertEq(yieldManager.harvestable(), 1_000e18, "harvestable should equal donated excess");
    }

    function test_maxDistribute() public {
        assertEq(yieldManager.maxDistribute(), 0, "empty buffer");
        fillBuffer(5e6);
        assertEq(yieldManager.maxDistribute(), 5e18, "buffer binds");
        fillBuffer(1_000e6);
        assertEq(yieldManager.maxDistribute(), MAX_PER_PERIOD, "max APR binds");
        vm.prank(admin);
        yieldManager.setAbsoluteCap(20e18);
        assertEq(yieldManager.maxDistribute(), 20e18, "absolute cap binds");
    }

    function test_name() public view {
        assertEq(yieldManager.NAME(), "VUSD-YieldManager", "name should be symbol-suffixed");
    }

    function test_treasuryAndGatewayResolution() public view {
        assertEq(address(yieldManager.treasury()), address(treasury), "treasury mismatch");
        assertEq(address(yieldManager.gateway()), address(gateway), "gateway mismatch");
    }

    function test_undistributed_zeroBeforeFirstDistribution() public view {
        assertEq(yieldManager.undistributed(), 0, "never funded");
    }

    function test_undistributed_zeroAfterPeriodFinish() public {
        fillBuffer(1_000e6);
        distributeAt(APY_BPS);
        skip(PERIOD + 1);
        assertEq(yieldManager.undistributed(), 0, "drip finished");
    }

    function test_undistributed_excludesPendingYield() public {
        fillBuffer(1_000e6);
        distributeAt(APY_BPS);
        skip(3 days);

        assertGt(distributor.pendingYield(), 0, "yield accrued");
        assertApproxEqAbs(yieldManager.undistributed(), dripLeft(), 1, "only what is still to drip");
    }

    function test_undistributed_keepsStaleCheckpointWithoutShares() public {
        fillBuffer(1_000e6);
        distributeAt(APY_BPS);
        skip(1 days);
        uint256 shares = stakingVault.balanceOf(alice);
        vm.prank(alice);
        stakingVault.requestRedeem(shares, alice);
        uint256 atExit = yieldManager.undistributed();
        skip(2 days);

        // Nothing is pulled without shares, so the distributor would roll over from its last checkpoint
        assertEq(distributor.pendingYield(), 0, "no shares, no pending");
        assertEq(yieldManager.undistributed(), atExit, "rollover measured from the exit");
    }

    function test_undistributed_keepsCheckpointWhenPullRoundsToZero() public {
        fillBuffer(1_000e6);
        // Under 1 wei per second: a 1-second pull rounds to 0 and leaves the distributor checkpoint in place
        yieldManager.distribute(600_000);
        skip(1);
        assertEq(distributor.pendingYield(), 0, "pull rounds to 0");

        uint256 rolled = yieldManager.undistributed();
        yieldManager.distribute(600_000);
        assertApproxEqAbs(dripLeft(), rolled + 600_000, 2, "distributor rolled over what the mirror predicted");
    }
}
