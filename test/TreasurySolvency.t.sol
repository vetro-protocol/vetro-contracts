// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PeggedToken} from "src/PeggedToken.sol";
import {Gateway} from "src/Gateway.sol";
import {Treasury} from "src/Treasury.sol";
import {deployTreasury} from "test/helpers/Deploy.sol";
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
        treasury = deployTreasury(address(vusd), owner);
        vusd.updateTreasury(address(treasury));
        // The tests act as keeper and maintainer
        treasury.grantRole(treasury.KEEPER_ROLE(), address(this));
        treasury.grantRole(treasury.MAINTAINER_ROLE(), address(this));

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

    function test_harvest_liquidityAwareVault_paysWhatTheVaultCanRelease() public {
        _mint(alice, 1_000e18);
        _simulateVaultYield(100e18);

        // The vault reports only part of the excess as withdrawable: harvest takes that much instead of reverting
        vault.setLiquidityAwareMaxWithdraw(true);
        vault.setLiquidCap(40e18);
        uint256 harvested = treasury.harvest(address(collateral), owner);
        assertEq(harvested, 40e18, "harvest pays what the vault can release");
        assertEq(collateral.balanceOf(owner), 40e18);
        assertApproxEqAbs(treasury.reserve(), vusd.totalSupply() + 60e18, 1, "the rest stays harvestable");
    }

    function test_harvest_liquidityAwareVault_reducesNetDepositedByWhatItPays() public {
        _mint(alice, 1_000e18);
        _simulateVaultYield(100e18);

        vault.setLiquidityAwareMaxWithdraw(true);
        vault.setLiquidCap(40e18);
        assertEq(treasury.harvest(address(collateral), owner), 40e18);
        assertEq(treasury.netDeposited(address(collateral)), 960e18, "the 40 paid, not the 100 of excess");
    }

    function test_redeem_afterVaultYield_reducesNetDepositedByAssets() public {
        _mint(alice, 100e18);
        // Each share is now worth 2 collateral
        _simulateVaultYield(100e18);

        vm.prank(alice);
        gateway.redeem(address(collateral), 40e18, 0, alice);
        assertEq(collateral.balanceOf(alice), 40e18);
        assertEq(treasury.netDeposited(address(collateral)), 60e18, "the 40 paid out, not the 20 shares");
    }

    function test_harvest_revertsWhenTheVaultCannotRelease() public {
        _mint(alice, 1_000e18);
        _simulateVaultYield(100e18);

        // maxWithdraw is book value, so harvest asks for the whole excess and the vault reverts
        vault.setLiquidCap(40e18);
        vm.expectRevert("MockYieldVaultRealistic: illiquid");
        treasury.harvest(address(collateral), owner);
    }

    /*//////////////////////////////////////////////////////////////
                        RESERVE UNDER ABOVE-PAR ORACLE
    //////////////////////////////////////////////////////////////*/

    // Harvest during an in-tolerance up-tick and re-mint the excess at par, as YieldManager does.
    function test_abovePegTick_harvestAndRemint_keepsSupplyBacked() public {
        uint256 amount = 1_000e18;
        _mint(alice, amount);

        oracle.updatePrice(1.005e8);
        uint256 harvested = treasury.harvest(address(collateral), owner);
        if (harvested > 0) {
            collateral.approve(address(gateway), harvested);
            gateway.deposit(address(collateral), harvested, 0, owner);
        }

        oracle.updatePrice(1e8);
        assertGe(treasury.reserve(), vusd.totalSupply(), "supply must stay backed once the price returns to par");
    }

    function testFuzz_priceTick_harvestAndRemint_keepsSupplyBacked(uint256 price_, uint256 yield_) public {
        price_ = bound(price_, 0.99e8, 1.01e8);
        yield_ = bound(yield_, 0, 100e18);
        _mint(alice, 1_000e18);
        _simulateVaultYield(yield_);

        oracle.updatePrice(int256(price_));
        bool hadExcess = treasury.reserve() > vusd.totalSupply();
        uint256 harvested = treasury.harvest(address(collateral), owner);
        assertLe(harvested, yield_, "harvest must not exceed real yield");
        if (hadExcess) {
            // Harvest releases the excess measured at the same capped price, leaving only rounding dust
            assertGe(treasury.reserve(), vusd.totalSupply(), "harvest must not take more than the excess");
            assertApproxEqAbs(treasury.reserve(), vusd.totalSupply(), 10, "harvest should take the whole excess");
        } else {
            assertEq(harvested, 0, "nothing to harvest without excess");
        }
        if (harvested > 0) {
            collateral.approve(address(gateway), harvested);
            gateway.deposit(address(collateral), harvested, 0, owner);
        }

        oracle.updatePrice(1e8);
        assertGe(treasury.reserve(), vusd.totalSupply(), "supply must stay backed once the price returns to par");
    }

    /*//////////////////////////////////////////////////////////////
                        HARVEST UNDER PEG BAND
    //////////////////////////////////////////////////////////////*/

    function _collateralHeld() internal view returns (uint256) {
        return collateral.balanceOf(address(treasury)) + vault.convertToAssets(vault.balanceOf(address(treasury)));
    }

    // Harvest and re-mint the collateral through the Gateway, as YieldManager does
    function _harvestAndRemint() internal returns (uint256 excessBefore, uint256 minted) {
        uint256 _reserve = treasury.reserve();
        uint256 _supply = vusd.totalSupply();
        excessBefore = _reserve > _supply ? _reserve - _supply : 0;
        uint256 _harvested = treasury.harvest(address(collateral), owner);
        if (_harvested > 0) {
            collateral.approve(address(gateway), _harvested);
            minted = gateway.deposit(address(collateral), _harvested, 0, owner);
        }
    }

    // Inside the band the Gateway mints at par, so harvest must convert the excess at par too
    function test_inBandPrice_harvestAndRemint_mintsAtMostExcess() public {
        treasury.updatePegBand(address(collateral), 50);
        _mint(alice, 1_000e18);
        _simulateVaultYield(10e18);
        oracle.updatePrice(0.997e8);

        (uint256 excess, uint256 minted) = _harvestAndRemint();
        assertLe(minted, excess, "remint must not exceed the excess");
        assertGe(treasury.reserve(), vusd.totalSupply(), "supply must stay backed at the same price");
    }

    function testFuzz_pegBand_harvestAndRemint_mintsAtMostExcess(
        uint256 price_,
        uint256 band_,
        uint256 yield_,
        uint256 mintFee_
    ) public {
        price_ = bound(price_, 0.99e8, 1.01e8);
        band_ = bound(band_, 0, 99);
        yield_ = bound(yield_, 0, 100e18);
        mintFee_ = bound(mintFee_, 0, 100);
        treasury.updatePegBand(address(collateral), band_);
        _mint(alice, 1_000e18);
        if (mintFee_ > 0) gateway.updateMintFee(address(collateral), mintFee_);
        _simulateVaultYield(yield_);
        oracle.updatePrice(int256(price_));

        (uint256 excess, uint256 minted) = _harvestAndRemint();
        assertLe(minted, excess + 2, "remint must not exceed the excess");
        if (excess > 0) {
            assertGe(treasury.reserve() + 2, vusd.totalSupply(), "supply must stay backed at the same price");
        }
        assertGe(_collateralHeld() + 2, vusd.totalSupply(), "collateral held must cover supply");

        oracle.updatePrice(1e8);
        assertGe(treasury.reserve() + 2, vusd.totalSupply(), "supply must stay backed once the price returns to par");
    }

    // Below the floor the Gateway mints at the oracle price, so one harvest takes the whole excess
    function test_belowFloorPrice_harvestAndRemint_takesWholeExcess() public {
        treasury.updatePegBand(address(collateral), 10);
        _mint(alice, 1_000e18);
        _simulateVaultYield(10e18);
        oracle.updatePrice(0.995e8);

        (uint256 excess, uint256 minted) = _harvestAndRemint();
        assertApproxEqAbs(minted, excess, 2, "remint should mint the whole excess");
        assertApproxEqAbs(treasury.reserve(), vusd.totalSupply(), 10, "no excess should be left behind");
    }

    // A receiver that keeps the collateral instead of re-minting it
    function testFuzz_harvestWithoutRemint_keepsSupplyBacked(uint256 price_, uint256 yield_) public {
        price_ = bound(price_, 0.99e8, 1.01e8);
        yield_ = bound(yield_, 0, 100e18);
        _mint(alice, 1_000e18);
        _simulateVaultYield(yield_);
        oracle.updatePrice(int256(price_));

        bool hadExcess = treasury.reserve() > vusd.totalSupply();
        treasury.harvest(address(collateral), owner);
        if (hadExcess) {
            assertGe(treasury.reserve() + 2, vusd.totalSupply(), "supply must stay backed at the same price");
        }
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

    function test_illiquidInstantRedeem_liquidityAwareVault_revertsAtGateway() public {
        uint256 amount = 1_000e18;
        _mint(alice, amount);

        uint256 liquid = 400e18;
        vault.setLiquidityAwareMaxWithdraw(true);
        vault.setLiquidCap(liquid); // strategy can only release 400 of the 1000 backing per call

        // withdrawable() follows the vault's maxWithdraw, which this vault caps at what it can deliver
        assertEq(treasury.withdrawable(address(collateral)), liquid, "withdrawable reports deliverable liquidity");
        assertEq(treasury.reserve(), amount, "reserve still counts the full accounting value");

        uint256 supplyBefore = vusd.totalSupply();
        uint256 aliceVusdBefore = vusd.balanceOf(alice);
        uint256 reserveBefore = treasury.reserve();

        // Redeeming beyond the liquid cap reverts at the Gateway...
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Gateway.ExceededMaxWithdraw.selector, 600e18, liquid));
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

    function test_illiquidLockedRedeem_liquidityAwareVault_escrowIntact() public {
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

        vault.setLiquidityAwareMaxWithdraw(true);
        vault.setLiquidCap(400e18);
        (, uint256 claimableAt) = gateway.getRedeemRequest(alice);
        vm.warp(claimableAt);
        oracle.updatePrice(1e8); // refresh after warp so the revert is illiquidity, not staleness

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Gateway.ExceededMaxWithdraw.selector, lockAmount, 400e18));
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

    function test_shutdownVault_limitsRedeemToIdle() public {
        _mint(alice, 1_000e18);
        deal(address(collateral), address(treasury), 100e18);

        // A shut-down vault (yield-vault main) reports nothing withdrawable and takes no deposits
        vault.setShutdown(true);
        assertEq(treasury.withdrawable(address(collateral)), 100e18, "only the idle balance is withdrawable");
        assertEq(gateway.maxDeposit(address(collateral)), 0, "the vault takes no deposits");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Gateway.ExceededMaxWithdraw.selector, 150e18, 100e18));
        gateway.redeem(address(collateral), 150e18, 0, alice);

        vm.prank(alice);
        gateway.redeem(address(collateral), 100e18, 0, alice);
        assertEq(collateral.balanceOf(alice), 100e18, "the idle balance still redeems");
    }

    function test_shutdownVault_harvestPaysFromIdle() public {
        _mint(alice, 1_000e18);
        _simulateVaultYield(100e18);
        deal(address(collateral), address(treasury), 50e18);

        // 150 excess, 50 of it idle: harvest skips the shut-down vault and pays the idle part
        vault.setShutdown(true);
        assertEq(treasury.harvest(address(collateral), owner), 50e18);
        assertEq(collateral.balanceOf(owner), 50e18);
    }
}
