// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Gateway} from "src/Gateway.sol";
import {Treasury} from "src/Treasury.sol";
import {PeggedToken} from "src/PeggedToken.sol";
import {YieldDistributor} from "src/YieldDistributor.sol";
import {YieldManager} from "src/YieldManager.sol";
import {IPeggedToken} from "src/interfaces/IPeggedToken.sol";
import {IYieldDistributor} from "src/interfaces/IYieldDistributor.sol";
import {MockChainlinkOracle} from "test/mocks/MockChainlinkOracle.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockYieldVault} from "test/mocks/MockYieldVault.sol";

contract YieldManagerTest is Test {
    using SafeERC20 for IERC20;

    PeggedToken peggedToken;
    Gateway gateway;
    Treasury treasury;
    YieldDistributor distributor;
    YieldManager yieldManager;
    address owner;
    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");
    address stakingVault = makeAddr("stakingVault");
    address token;
    MockChainlinkOracle mockOracle;
    MockYieldVault mockVault;

    uint256 constant INITIAL_DEPOSIT = 100_000e6; // 6-decimals collateral

    event HarvestedAndDistributed(address indexed token, uint256 tokenAmount, uint256 peggedTokenAmount);
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

        YieldDistributor distributorImpl = new YieldDistributor();
        bytes memory distributorInit =
            abi.encodeWithSelector(YieldDistributor.initialize.selector, address(peggedToken), stakingVault, admin);
        distributor = YieldDistributor(address(new ERC1967Proxy(address(distributorImpl), distributorInit)));

        yieldManager = new YieldManager(IPeggedToken(address(peggedToken)), IYieldDistributor(address(distributor)));

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
        vm.stopPrank();
    }

    /// @dev Simulates yield by donating collateral to the treasury (loose balance counts in reserve)
    function createExcess(uint256 tokenAmount) internal {
        deal(token, address(this), tokenAmount);
        IERC20(token).safeTransfer(address(treasury), tokenAmount);
    }

    function assertBackingInvariant() internal view {
        assertGe(
            treasury.reserve(), peggedToken.totalSupply() - gateway.amoSupply(), "reserve must cover backed supply"
        );
    }

    // --- constructor ---

    function test_constructor_revertIfAddressIsZero() public {
        vm.expectRevert(YieldManager.AddressIsZero.selector);
        new YieldManager(IPeggedToken(address(0)), IYieldDistributor(address(distributor)));

        vm.expectRevert(YieldManager.AddressIsZero.selector);
        new YieldManager(IPeggedToken(address(peggedToken)), IYieldDistributor(address(0)));
    }

    function test_constructor_revertIfAssetMismatch() public {
        YieldDistributor otherImpl = new YieldDistributor();
        bytes memory otherInit =
            abi.encodeWithSelector(YieldDistributor.initialize.selector, token, stakingVault, admin);
        YieldDistributor otherDistributor = YieldDistributor(address(new ERC1967Proxy(address(otherImpl), otherInit)));

        vm.expectRevert(YieldManager.AssetMismatch.selector);
        new YieldManager(IPeggedToken(address(peggedToken)), IYieldDistributor(address(otherDistributor)));
    }

    // --- harvestAndDistribute ---

    function test_harvestAndDistribute() public {
        createExcess(1_000e6);

        uint256 expected = 1_000e18;
        assertEq(yieldManager.harvestable(), expected, "harvestable should equal donated excess");

        vm.expectEmit();
        emit HarvestedAndDistributed(token, 1_000e6, expected);
        vm.prank(keeper);
        uint256 distributed = yieldManager.harvestAndDistribute(token, expected);

        assertEq(distributed, expected, "distributed amount mismatch");
        assertEq(peggedToken.balanceOf(address(distributor)), expected, "distributor did not receive yield");
        assertEq(peggedToken.balanceOf(address(yieldManager)), 0, "yieldManager must hold nothing");
        assertEq(IERC20(token).balanceOf(address(yieldManager)), 0, "yieldManager must hold no collateral");
        assertEq(yieldManager.harvestable(), 0, "excess should be fully harvested");
        assertBackingInvariant();
    }

    function test_harvestAndDistribute_excessInVault() public {
        // Push the donated excess into the yield vault to exercise harvest's vault-withdraw leg
        createExcess(1_000e6);
        treasury.push(token, 1_000e6);
        assertEq(IERC20(token).balanceOf(address(treasury)), 0, "excess should sit in the vault");

        vm.prank(keeper);
        uint256 distributed = yieldManager.harvestAndDistribute(token, 1_000e18);

        assertEq(distributed, 1_000e18, "distributed amount mismatch");
        assertBackingInvariant();
    }

    function test_harvestAndDistribute_withMintFee() public {
        gateway.updateMintFee(token, 50); // 0.5%
        createExcess(1_000e6);

        vm.prank(keeper);
        uint256 distributed = yieldManager.harvestAndDistribute(token, 995e18);

        assertEq(distributed, 995e18, "distributed should be net of mint fee");
        // The fee remainder stays in the treasury as excess for the next cycle
        assertEq(yieldManager.harvestable(), 5e18, "fee remainder should stay harvestable");
        assertBackingInvariant();
    }

    function test_harvestAndDistribute_priceBelowParWithinTolerance() public {
        mockOracle.updatePrice(0.995e8); // 0.5% below par, within the treasury's 1% priceTolerance
        createExcess(1_000e6);

        // Repricing shrinks the whole reserve: excess = 101_000 * 0.995 - 100_000 = 495 pegged.
        // Harvest converts it back to ~497.49 tokens, which mint at price (pegBand = 0 => below pegFloor).
        uint256 expected = 495e18;

        vm.prank(keeper);
        uint256 distributed = yieldManager.harvestAndDistribute(token, 0);

        assertApproxEqAbs(distributed, expected, 1e12, "distributed should be valued at price");
        assertBackingInvariant();
    }

    function test_harvestAndDistribute_revertIfPriceExceedsTolerance() public {
        createExcess(1_000e6);
        mockOracle.updatePrice(0.98e8); // 2% below par, beyond the treasury's 1% priceTolerance

        // The treasury-level depeg circuit-breaker fires inside harvest's getPrice call
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Treasury.PriceExceedTolerance.selector, 0.98e8, 1.01e8, 0.99e8));
        yieldManager.harvestAndDistribute(token, 0);
    }

    function test_harvestAndDistribute_revertIfMinOutTooHigh() public {
        createExcess(1_000e6);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Gateway.MintableIsLessThanMinimum.selector, 1_000e18, 1_000e18 + 1));
        yieldManager.harvestAndDistribute(token, 1_000e18 + 1);
    }

    function test_harvestAndDistribute_revertIfNothingHarvested() public {
        vm.prank(keeper);
        vm.expectRevert(YieldManager.NothingHarvested.selector);
        yieldManager.harvestAndDistribute(token, 0);
    }

    function test_harvestAndDistribute_revertIfNotKeeper() public {
        bytes32 keeperRole = yieldManager.KEEPER_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(YieldManager.AccessControlUnauthorizedAccount.selector, alice, keeperRole)
        );
        yieldManager.harvestAndDistribute(token, 0);
    }

    function test_harvestAndDistribute_errantPeggedDustRidesAlong() public {
        // Pegged dust sitting on the manager is distributed together with the next real harvest
        vm.prank(alice);
        assertTrue(peggedToken.transfer(address(yieldManager), 1e18));
        createExcess(1_000e6);

        vm.prank(keeper);
        uint256 distributed = yieldManager.harvestAndDistribute(token, 1_000e18);

        assertEq(distributed, 1_001e18, "dust should ride along with the harvest");
        assertEq(peggedToken.balanceOf(address(distributor)), 1_001e18, "distributor should receive harvest + dust");
        assertEq(peggedToken.balanceOf(address(yieldManager)), 0, "yieldManager must hold nothing");
    }

    // --- views ---

    function test_harvestable() public {
        assertEq(yieldManager.harvestable(), 0, "no excess initially");
        createExcess(1_000e6);
        assertEq(yieldManager.harvestable(), 1_000e18, "harvestable should equal donated excess");
    }

    function test_name() public view {
        assertEq(yieldManager.NAME(), "VUSD-YieldManager", "name should be symbol-suffixed");
    }

    function test_treasuryAndGatewayResolution() public view {
        assertEq(address(yieldManager.treasury()), address(treasury), "treasury mismatch");
        assertEq(address(yieldManager.gateway()), address(gateway), "gateway mismatch");
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
}
