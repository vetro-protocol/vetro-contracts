// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Gateway} from "src/Gateway.sol";
import {PeggedToken} from "src/PeggedToken.sol";
import {StakingVault} from "src/StakingVault.sol";
import {Treasury} from "src/Treasury.sol";
import {YieldDistributor} from "src/YieldDistributor.sol";
import {YieldManager} from "src/YieldManager.sol";
import {IPeggedToken} from "src/interfaces/IPeggedToken.sol";
import {IYieldDistributor} from "src/interfaces/IYieldDistributor.sol";
import {MockChainlinkOracle} from "test/mocks/MockChainlinkOracle.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockYieldVault} from "test/mocks/MockYieldVault.sol";

/// @title YieldManager Invariant Test Handler
/// @notice Random staking, time, buffer, keeper and admin actions around a YieldManager
contract YieldManagerHandler is Test {
    using SafeERC20 for IERC20;

    YieldManager public yieldManager;
    YieldDistributor public distributor;
    StakingVault public vault;
    IERC20 public peggedToken;
    Treasury public treasury;
    address public token;
    address public keeper;
    address public admin;
    address[] public actors;

    // Ghost variables for tracking
    uint256 public ghost_bufferIn;
    uint256 public ghost_distributed;
    uint256 public ghost_capAtLastDistribution;
    uint256 public ghost_distributeCount;
    bool public ghost_dripAboveCap;
    bool public ghost_maxDistributeRejected;
    bool public ghost_aboveMaxDistributeAccepted;

    uint256 constant YEAR = 365 days;

    constructor(YieldManager yieldManager_, Treasury treasury_, address token_, address keeper_, address admin_) {
        yieldManager = yieldManager_;
        distributor = YieldDistributor(address(yieldManager_.YIELD_DISTRIBUTOR()));
        vault = StakingVault(distributor.vault());
        peggedToken = IERC20(address(yieldManager_.PEGGED_TOKEN()));
        treasury = treasury_;
        token = token_;
        keeper = keeper_;
        admin = admin_;
        actors.push(makeAddr("actor0"));
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
    }

    function deposit(uint256 actorSeed_, uint256 amount_) external {
        address _actor = actors[actorSeed_ % actors.length];
        amount_ = bound(amount_, 1e18, 50_000e18);
        if (peggedToken.balanceOf(address(this)) < amount_) return;

        peggedToken.safeTransfer(_actor, amount_);
        vm.startPrank(_actor);
        peggedToken.forceApprove(address(vault), amount_);
        vault.deposit(amount_, _actor);
        vm.stopPrank();
    }

    function requestRedeem(uint256 actorSeed_, uint256 fraction_) external {
        address _actor = actors[actorSeed_ % actors.length];
        uint256 _shares = vault.balanceOf(_actor) * bound(fraction_, 1, 100) / 100;
        if (_shares == 0 || vault.previewRedeem(_shares) == 0) return;

        vm.prank(_actor);
        vault.requestRedeem(_shares, _actor);
    }

    function warp(uint256 seconds_) external {
        skip(bound(seconds_, 0, 2 days));
    }

    function fillBuffer(uint256 amount_) external {
        amount_ = bound(amount_, 1e6, 1_000e6);
        deal(token, address(this), amount_);
        IERC20(token).safeTransfer(address(treasury), amount_);

        vm.prank(keeper);
        ghost_bufferIn += yieldManager.harvest(token, 0);
    }

    function distributeForApy(uint256 apyBps_) external {
        uint256 _amount = yieldManager.amountForApy(bound(apyBps_, 1, yieldManager.MAX_APY_BPS()));
        _amount = _min(_amount, yieldManager.maxDistribute());
        if (_amount == 0) return;
        _distribute(_amount);
    }

    function distributeMax() external {
        uint256 _amount = yieldManager.maxDistribute();
        if (_amount == 0) return;
        _distribute(_amount);
    }

    /// @dev Anything above the headroom by more than the mirror's rounding must be rejected
    function distributeAboveMax(uint256 excess_) external {
        uint256 _amount = yieldManager.maxDistribute() + bound(excess_, 3, 1_000e18);
        if (_amount > yieldManager.buffer()) return;

        vm.prank(keeper);
        try yieldManager.distribute(_amount) {
            ghost_aboveMaxDistributeAccepted = true;
        } catch {}
    }

    function setMaxApy(uint256 maxApyBps_) external {
        maxApyBps_ = bound(maxApyBps_, 0, yieldManager.MAX_APY_BPS());
        vm.prank(admin);
        yieldManager.setMaxApy(maxApyBps_);
    }

    function setAbsoluteCap(uint256 absoluteCap_) external {
        vm.prank(admin);
        yieldManager.setAbsoluteCap(bound(absoluteCap_, 1, 1_000e18));
    }

    function updateYieldDuration(uint256 duration_) external {
        vm.prank(admin);
        distributor.updateYieldDuration(bound(duration_, 1 days, 14 days));
    }

    function dripLeft() public view returns (uint256) {
        uint256 _finish = distributor.periodFinish();
        if (block.timestamp >= _finish) return 0;
        return ((_finish - block.timestamp) * distributor.rewardRate()) / 1e18;
    }

    function _distribute(uint256 amount_) private {
        uint256 _cap = _expectedCap();
        vm.prank(keeper);
        try yieldManager.distribute(amount_) {
            ghost_distributed += amount_;
            ghost_capAtLastDistribution = _cap;
            ghost_distributeCount++;
            if (dripLeft() > _cap) ghost_dripAboveCap = true;
        } catch {
            ghost_maxDistributeRejected = true;
        }
    }

    /// @dev Independent recomputation of `min(maxApyBps on totalAssets, absoluteCap per 7 days)` for one period
    function _expectedCap() private view returns (uint256) {
        if (vault.totalSupply() == 0) return 0;
        uint256 _duration = distributor.yieldDuration();
        uint256 _apyCap = vault.totalAssets() * yieldManager.maxApyBps() * _duration / (10_000 * YEAR);
        return _min(_apyCap, yieldManager.absoluteCap() * _duration / 7 days);
    }

    function _min(uint256 a_, uint256 b_) private pure returns (uint256) {
        return a_ < b_ ? a_ : b_;
    }
}

/// @title YieldManager Invariant Tests
contract YieldManagerInvariantTest is Test {
    using SafeERC20 for IERC20;

    YieldManagerHandler public handler;
    YieldManager public yieldManager;
    YieldDistributor public distributor;
    StakingVault public vault;
    PeggedToken public peggedToken;
    Treasury public treasury;

    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");

    function setUp() public {
        peggedToken = new PeggedToken("VUSD", "VUSD", address(this));
        treasury = new Treasury(address(peggedToken), admin);
        peggedToken.updateTreasury(address(treasury));

        Gateway gatewayImpl = new Gateway();
        Gateway gateway = Gateway(
            address(
                new ERC1967Proxy(
                    address(gatewayImpl),
                    abi.encodeCall(Gateway.initialize, (address(peggedToken), type(uint256).max, 7 days))
                )
            )
        );
        peggedToken.updateGateway(address(gateway));

        StakingVault vaultImpl = new StakingVault();
        vault = StakingVault(
            address(
                new ERC1967Proxy(
                    address(vaultImpl),
                    abi.encodeCall(
                        StakingVault.initialize, (address(peggedToken), "Staked VUSD", "sVUSD", address(this))
                    )
                )
            )
        );

        YieldDistributor distributorImpl = new YieldDistributor();
        distributor = YieldDistributor(
            address(
                new ERC1967Proxy(
                    address(distributorImpl),
                    abi.encodeCall(YieldDistributor.initialize, (address(peggedToken), address(vault), admin))
                )
            )
        );
        vault.updateYieldDistributor(address(distributor));

        yieldManager = new YieldManager(
            IPeggedToken(address(peggedToken)), IYieldDistributor(address(distributor)), 1_500, 415e18
        );

        address token = address(new MockERC20());
        MockYieldVault yieldVault = new MockYieldVault(token);
        MockChainlinkOracle oracle = new MockChainlinkOracle(1e8);

        handler = new YieldManagerHandler(yieldManager, treasury, token, keeper, admin);

        vm.startPrank(admin);
        treasury.addToWhitelist(token, address(yieldVault), address(oracle), 365 days);
        treasury.grantRole(treasury.UMM_ROLE(), address(yieldManager));
        treasury.grantRole(treasury.KEEPER_ROLE(), keeper);
        distributor.grantRole(distributor.DISTRIBUTOR_ROLE(), address(yieldManager));
        vm.stopPrank();

        // Backed supply: the handler funds stakers from pegged tokens minted at par
        deal(token, address(handler), 1_000_000e6);
        vm.startPrank(address(handler));
        IERC20(token).forceApprove(address(gateway), 1_000_000e6);
        gateway.deposit(token, 1_000_000e6, 0, address(handler));
        vm.stopPrank();

        // Start with stakers and a buffer so distributions happen from the first call
        handler.deposit(0, 36_500e18);
        handler.fillBuffer(1_000e6);

        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 50
    function invariant_dripNeverAboveCapAtDistribution() public view {
        assertFalse(handler.ghost_dripAboveCap(), "drip above the cap computed before the call");
        assertLe(handler.dripLeft(), handler.ghost_capAtLastDistribution(), "drip grew without a distribution");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 50
    function invariant_maxDistributeIsExact() public view {
        assertFalse(handler.ghost_maxDistributeRejected(), "maxDistribute rejected");
        assertFalse(handler.ghost_aboveMaxDistributeAccepted(), "more than maxDistribute accepted");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 50
    function invariant_bufferConservation() public view {
        assertEq(
            yieldManager.buffer(),
            handler.ghost_bufferIn() - handler.ghost_distributed(),
            "buffer must equal harvested minus distributed"
        );
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 50
    function invariant_distributorSolvent() public view {
        uint256 _owed = distributor.lastUpdateTime() < distributor.periodFinish()
            ? (distributor.periodFinish() - distributor.lastUpdateTime()) * distributor.rewardRate() / 1e18
            : 0;
        assertGe(peggedToken.balanceOf(address(distributor)), _owed, "distributor must hold what it owes");
    }
}
