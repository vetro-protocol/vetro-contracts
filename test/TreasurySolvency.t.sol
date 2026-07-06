// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PeggedToken} from "src/PeggedToken.sol";
import {Gateway} from "src/Gateway.sol";
import {Treasury} from "src/Treasury.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockChainlinkOracle} from "test/mocks/MockChainlinkOracle.sol";
import {MockYieldVaultRealistic} from "test/mocks/MockYieldVaultRealistic.sol";

/// @dev Full-system harness (PeggedToken + Treasury + Gateway) wired to a realistic ERC4626 vault,
///      to exercise reserve accounting under share appreciation and the redeem-under-illiquidity path
///      that MockYieldVault's fixed-1:1, always-liquid behavior cannot reach.
contract TreasurySolvencyTest is Test {
    PeggedToken vusd;
    Treasury treasury;
    Gateway gateway;
    MockERC20 collateral;
    MockChainlinkOracle oracle;
    MockYieldVaultRealistic vault;

    address owner = address(this);
    address alice = makeAddr("alice");

    uint256 constant STALE_PERIOD = 1 days;

    function setUp() public {
        collateral = new MockERC20();
        collateral.setDecimals(18); // match PeggedToken so par math is exact (1 collateral <-> 1 VUSD)
        oracle = new MockChainlinkOracle(1e8); // 1.0 at 8 decimals
        vault = new MockYieldVaultRealistic(address(collateral));

        vusd = new PeggedToken("viaUSD", "viaUSD", owner);
        treasury = new Treasury(address(vusd), owner);
        vusd.updateTreasury(address(treasury));

        Gateway impl = new Gateway();
        bytes memory initData =
            abi.encodeWithSelector(Gateway.initialize.selector, address(vusd), type(uint256).max, 7 days);
        gateway = Gateway(address(new ERC1967Proxy(address(impl), initData)));

        vusd.updateGateway(address(gateway));
        treasury.grantRole(treasury.UMM_ROLE(), owner);
        gateway.setWithdrawalDelayEnabled(false);

        treasury.addToWhitelist(address(collateral), address(vault), address(oracle), STALE_PERIOD);
    }

    // Deposit `amount` collateral as `user`, minting an equal amount of VUSD at par.
    function _mint(address user, uint256 amount) internal {
        deal(address(collateral), user, amount);
        vm.startPrank(user);
        collateral.approve(address(gateway), amount);
        gateway.deposit(address(collateral), amount, 0, user);
        vm.stopPrank();
    }

    function _simulateVaultYield(uint256 amount) internal {
        deal(address(collateral), owner, amount);
        collateral.approve(address(vault), amount);
        vault.simulateYield(amount);
    }

    /*//////////////////////////////////////////////////////////////
                        RESERVE UNDER SHARE APPRECIATION
    //////////////////////////////////////////////////////////////*/

    function test_reserveReflectsVaultYield_andHarvestExtractsExcess() public {
        uint256 amount = 1_000e18;
        _mint(alice, amount);
        assertEq(treasury.reserve(), vusd.totalSupply(), "should be fully collateralized at par");

        uint256 yield = 100e18;
        _simulateVaultYield(yield);

        // Share price rose, so the reserve now values the same shares higher than the backed supply.
        assertEq(treasury.reserve(), amount + yield, "reserve should reflect vault appreciation");
        assertGt(treasury.reserve(), vusd.totalSupply(), "appreciation creates harvestable excess");

        uint256 harvested = treasury.harvest(address(collateral), owner);
        assertApproxEqAbs(harvested, yield, 1, "harvest should extract the excess");
        assertApproxEqAbs(treasury.reserve(), vusd.totalSupply(), 1, "reserve returns to backed supply");
    }

    /*//////////////////////////////////////////////////////////////
                        REDEEM UNDER ILLIQUIDITY
    //////////////////////////////////////////////////////////////*/

    function test_illiquidInstantRedeem_revertsCleanly_andWithdrawableOverstates() public {
        uint256 amount = 1_000e18;
        _mint(alice, amount);

        uint256 liquid = 400e18;
        vault.setLiquidCap(liquid); // strategy can only release 400 of the 1000 backing per call

        // withdrawable() prices the shares (accounting), so it overstates what can actually be delivered.
        assertEq(treasury.withdrawable(address(collateral)), amount, "withdrawable reports accounting value");
        assertGt(treasury.withdrawable(address(collateral)), liquid, "which exceeds deliverable liquidity");

        uint256 supplyBefore = vusd.totalSupply();
        uint256 aliceVusdBefore = vusd.balanceOf(alice);
        uint256 reserveBefore = treasury.reserve();

        // Redeeming within withdrawable() but beyond the liquid cap reverts at the vault...
        vm.prank(alice);
        vm.expectRevert("MockYieldVaultRealistic: illiquid");
        gateway.redeem(address(collateral), 600e18, 0, alice);

        // ...and the whole tx unwinds: no VUSD burned, no reserve change. Clean revert, no fund loss.
        assertEq(vusd.totalSupply(), supplyBefore, "no VUSD burned on the failed redeem");
        assertEq(vusd.balanceOf(alice), aliceVusdBefore, "alice keeps her VUSD");
        assertEq(treasury.reserve(), reserveBefore, "reserve unchanged");

        // A redeem within the liquid cap still settles.
        vm.prank(alice);
        gateway.redeem(address(collateral), liquid, 0, alice);
        assertEq(collateral.balanceOf(alice), liquid, "liquid portion redeems normally");
    }

    function test_illiquidLockedRedeem_revertsCleanly_escrowIntact() public {
        uint256 amount = 1_000e18;
        _mint(alice, amount);

        gateway.setWithdrawalDelayEnabled(true); // force the request -> claim (escrow) path

        uint256 lockAmount = 600e18;
        vm.startPrank(alice);
        vusd.approve(address(gateway), lockAmount); // requestRedeem pulls VUSD via transferFrom
        gateway.requestRedeem(lockAmount);
        vm.stopPrank();

        // VUSD is escrowed in the gateway, not burned yet.
        assertEq(vusd.balanceOf(address(gateway)), lockAmount, "locked VUSD held in gateway");
        uint256 supplyBefore = vusd.totalSupply();

        vault.setLiquidCap(400e18);
        (, uint256 claimableAt) = gateway.getRedeemRequest(alice);
        vm.warp(claimableAt);
        oracle.updatePrice(1e8); // refresh after warp so the revert is illiquidity, not staleness

        vm.prank(alice);
        vm.expectRevert("MockYieldVaultRealistic: illiquid");
        gateway.redeem(address(collateral), lockAmount, 0, alice);

        // Escrow intact: nothing burned, request still claimable later. No stuck-burn / fund loss.
        (uint256 stillLocked,) = gateway.getRedeemRequest(alice);
        assertEq(stillLocked, lockAmount, "request still fully locked");
        assertEq(vusd.balanceOf(address(gateway)), lockAmount, "escrowed VUSD untouched");
        assertEq(vusd.totalSupply(), supplyBefore, "no VUSD burned");

        // When liquidity returns the same claim settles.
        vault.setLiquidCap(0);
        vm.prank(alice);
        gateway.redeem(address(collateral), lockAmount, 0, alice);
        assertEq(collateral.balanceOf(alice), lockAmount, "claim settles once liquid");
        (uint256 finalLocked,) = gateway.getRedeemRequest(alice);
        assertEq(finalLocked, 0, "request cleared after successful claim");
    }
}
