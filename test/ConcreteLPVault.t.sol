// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ConcreteLPVault} from "src/ConcreteLPVault.sol";
import {Treasury} from "src/Treasury.sol";
import {YieldDistributor} from "src/YieldDistributor.sol";
import {ConcreteSpokeBase} from "test/ConcreteSpoke.t.sol";

contract ConcreteLPVaultTest is ConcreteSpokeBase {
    ConcreteLPVault vault;
    address vetroSafe = makeAddr("vetroSafe");
    uint64 constant VAULT_ROLE = 5;

    function setUp() public virtual override {
        super.setUp();
        bytes memory _init =
            abi.encodeCall(ConcreteLPVault.initialize, (address(manager), address(spoke), "Concrete sVUSD", "CsVUSD"));
        vault = ConcreteLPVault(address(new ERC1967Proxy(address(new ConcreteLPVault()), _init)));
        _whitelist(spoke, address(vault));

        bytes4[] memory _selectors = new bytes4[](3);
        _selectors[0] = ConcreteLPVault.setWhitelisted.selector;
        _selectors[1] = ConcreteLPVault.harvestExtraAssets.selector;
        _selectors[2] = ConcreteLPVault.setVetroTreasury.selector;
        vm.startPrank(admin);
        manager.setTargetFunctionRole(address(vault), _selectors, VAULT_ROLE);
        manager.grantRole(VAULT_ROLE, vetroSafe, 0);
        vm.stopPrank();

        // The vault unstakes the extra itself
        svusd.updateInstantWithdrawWhitelist(address(vault), true);

        vm.startPrank(vetroSafe);
        vault.setVetroTreasury(vetroSafe);
        vault.setWhitelisted(lp1, true);
        vault.setWhitelisted(lp2, true);
        vm.stopPrank();
    }

    /*/////////////////////////////////////////////////////////////
                            HELPERS
    /////////////////////////////////////////////////////////////*/

    function _depositCt(address lp_, uint256 ct_) internal returns (uint256 _shares) {
        ct.mint(lp_, ct_);
        vm.startPrank(lp_);
        ct.approve(address(vault), ct_);
        _shares = vault.deposit(ct_, lp_);
        vm.stopPrank();
    }

    function _redeemAllToCt(address lp_) internal returns (uint256) {
        uint256 _shares = vault.balanceOf(lp_);
        vm.prank(lp_);
        return vault.redeem(_shares, lp_, lp_);
    }

    /// @dev UMM harvests the spoke's surplus (keeps spoke supply level with its reserve so exits aren't capped)
    function _harvestSpoke() internal returns (uint256) {
        return _harvest(address(spoke));
    }

    /// @dev Vetro stakes the vault's shortfall to it (VUSD sourced from a core deposit here)
    function _topUp() internal returns (uint256 _vusd) {
        uint256 _short = vault.shortfallSVusd();
        if (_short == 0) return 0;
        _vusd = svusd.previewMint(_short);
        _coreDeposit(address(this), _vusd / 1e12 + 1);
        vusd.approve(address(svusd), _vusd);
        svusd.deposit(_vusd, address(vault));
    }

    /// @dev sVUSD yield: VUSD minted through the core and dripped over the full duration
    function _drip(uint256 amount_) internal {
        amount_ = amount_ / 1e12 * 1e12; // whole USDT units
        _coreDeposit(address(this), amount_ / 1e12);
        YieldDistributor _distributor = YieldDistributor(svusd.yieldDistributor());
        vm.startPrank(admin);
        _distributor.grantRole(_distributor.DISTRIBUTOR_ROLE(), address(this));
        vm.stopPrank();
        vusd.approve(address(_distributor), amount_);
        _distributor.distribute(amount_);
        _skip(_distributor.DEFAULT_YIELD_DURATION());
    }

    /*/////////////////////////////////////////////////////////////
                            ENTRY
    /////////////////////////////////////////////////////////////*/

    function test_depositCt_oneSharePerCt() public {
        assertEq(vault.decimals(), 6, "shares carry ct decimals");
        assertEq(_depositCt(lp1, 1_000e6), 1_000e6);
        assertEq(svusd.balanceOf(address(vault)), 1_000e18, "vault holds sVUSD");
        assertEq(vault.asset(), address(ct));
        assertEq(vault.totalAssets(), 1_000e6);
        assertEq(ct.balanceOf(address(spoke)), 1_000e6);
        assertEq(vault.shortfallSVusd(), 0);
        assertEq(vault.extraSVusd(), 0);
    }

    function test_depositCt_atSharePrice() public {
        ct.setRate(1.05e18);
        assertEq(_depositCt(lp1, 100e6), 100e6, "1 share per ct, at any share price");
        assertEq(svusd.balanceOf(address(vault)), 105e18);
    }

    function test_previewDepositMatchesDeposit() public {
        ct.setRate(1.25e18);
        uint256 _preview = vault.previewDeposit(100e6);
        assertEq(_depositCt(lp1, 100e6), _preview);
        assertEq(_preview, 100e6);
        assertEq(svusd.balanceOf(address(vault)), 125e18);
    }

    function test_donation_doesNotMoveSharePrice() public {
        _coreDeposit(address(this), 1_000e6);
        vusd.approve(address(svusd), 1_000e18);
        svusd.deposit(1_000e18, address(vault));
        assertEq(_depositCt(lp1, 100e6), 100e6);
        assertApproxEqAbs(vault.extraSVusd(), 1_000e18, 1e12, "donation is only extra");
        assertEq(_redeemAllToCt(lp1), 100e6);
    }

    /*/////////////////////////////////////////////////////////////
                    CASE A: CT EARNS MORE -> TOP UP
    /////////////////////////////////////////////////////////////*/

    function test_caseA_topUpThenExitOneToOne() public {
        _depositCt(lp1, 1_000e6);
        ct.setRate(1.1e18);
        assertEq(vault.shortfallSVusd(), 100e18, "owed 1100 VUSD of sVUSD, holds 1000");
        assertEq(_harvestSpoke(), 100e18);

        _topUp();
        assertEq(vault.shortfallSVusd(), 0);
        assertEq(vault.previewRedeem(1_000e6), 1_000e6);
        assertEq(_redeemAllToCt(lp1), 1_000e6, "exactly the ct deposited");
    }

    /// @dev Before the top-up an exit is pro rata; the rest are made whole once it lands
    function test_caseA_exitBeforeTopUpIsProRata() public {
        _depositCt(lp1, 500e6);
        _depositCt(lp2, 500e6);
        ct.setRate(1.1e18);
        _harvestSpoke();

        assertApproxEqAbs(vault.previewRedeem(500e6), 454_545_454, 2, "1000 sVUSD / 1100 owed");
        assertApproxEqAbs(_redeemAllToCt(lp1), 454_545_454, 2);
        _topUp();
        assertEq(_redeemAllToCt(lp2), 500e6, "the remaining LP is whole after the top-up");
    }

    /// @dev Deposits while short are at 1:1, so the newcomer neither buys into nor dilutes the pending top-up
    function test_caseA_depositWhileShortDoesNotDilute() public {
        _depositCt(lp1, 1_000e6);
        ct.setRate(1.1e18);
        _harvestSpoke();
        assertEq(_depositCt(lp2, 1_000e6), 1_000e6);
        assertApproxEqAbs(vault.shortfallSVusd(), 100e18, 1, "only lp1's pending top-up");

        _topUp();
        assertEq(_redeemAllToCt(lp1), 1_000e6);
        assertEq(_redeemAllToCt(lp2), 1_000e6);
    }

    /*/////////////////////////////////////////////////////////////
                CASE B: SVUSD EARNS MORE -> CLAW BACK
    /////////////////////////////////////////////////////////////*/

    function test_caseB_harvestExtraThenExitOneToOne() public {
        _depositCt(lp1, 1_000e6);
        ct.setRate(1.04e18);
        _drip(80e18); // vault is the only staker: +80
        _harvestSpoke();

        uint256 _extra = vault.extraSVusd();
        assertApproxEqRel(svusd.previewRedeem(_extra), 40e18, 0.001e18, "1080 held - 1040 owed");
        vm.prank(vetroSafe);
        (uint256 _sVusdIn, uint256 _vusdOut) = vault.harvestExtraAssets();
        assertEq(_sVusdIn, _extra);
        assertApproxEqRel(_vusdOut, 40e18, 0.001e18, "unstaked to VUSD, ready to drip again");
        assertEq(vusd.balanceOf(vetroSafe), _vusdOut);
        assertEq(svusd.balanceOf(vetroSafe), 0);
        assertEq(vault.shortfallSVusd(), 0);
        assertEq(_redeemAllToCt(lp1), 1_000e6, "never overpaid");
    }

    /// @dev Without the claw-back the share is still capped at 1 ct: the extra stays in the vault
    function test_caseB_shareCappedAtOneCt() public {
        _depositCt(lp1, 1_000e6);
        ct.setRate(1.04e18);
        _drip(80e18);
        _harvestSpoke();
        assertEq(vault.previewRedeem(1_000e6), 1_000e6);
        assertEq(_redeemAllToCt(lp1), 1_000e6);
        assertGt(svusd.balanceOf(address(vault)), 0, "extra left behind for Vetro");
    }

    function test_withdraw_exactCt() public {
        _depositCt(lp1, 1_000e6);
        ct.setRate(1.04e18);
        _drip(80e18);
        _harvestSpoke();
        assertEq(vault.maxWithdraw(lp1), 1_000e6);
        vm.prank(lp1);
        assertEq(vault.withdraw(400e6, lp1, lp1), 400e6, "400 shares for 400 ct");
        assertEq(ct.balanceOf(lp1), 400e6);
        assertEq(vault.balanceOf(lp1), 600e6);
    }

    /*/////////////////////////////////////////////////////////////
                            LOSS
    /////////////////////////////////////////////////////////////*/

    function test_loss_depositsRefusedAndNoClawBack() public {
        _depositCt(lp1, 1_000e6);
        ct.setRate(0.9e18);
        assertEq(vault.maxDeposit(lp2), 0);

        ct.mint(lp2, 1e6);
        vm.startPrank(lp2);
        ct.approve(address(vault), 1e6);
        vm.expectRevert();
        vault.deposit(1e6, lp2);
        vm.stopPrank();

        vm.prank(vetroSafe);
        vm.expectRevert(abi.encodeWithSelector(ConcreteLPVault.SpokeUndercollateralized.selector, 900e18, 1_000e18));
        vault.harvestExtraAssets();

        assertEq(_redeemAllToCt(lp1), 1_000e6, "the vault's own sVUSD still buys its ct back");
    }

    /*/////////////////////////////////////////////////////////////
                            WHITELIST
    /////////////////////////////////////////////////////////////*/

    function test_whitelist_gatesDepositsAndTransfers() public {
        ct.mint(stranger, 1e6);
        vm.startPrank(stranger);
        ct.approve(address(vault), 1e6);
        vm.expectRevert();
        vault.deposit(1e6, stranger);
        vm.stopPrank();

        _depositCt(lp1, 100e6);
        vm.prank(lp1);
        vm.expectRevert(abi.encodeWithSelector(ConcreteLPVault.NotWhitelisted.selector, stranger));
        vault.transfer(stranger, 1e6);

        vm.prank(lp1);
        vault.transfer(lp2, 10e6);
        assertEq(vault.balanceOf(lp2), 10e6);
    }

    function test_whitelist_removedHolderCanStillExit() public {
        _depositCt(lp1, 100e6);
        vm.prank(vetroSafe);
        vault.setWhitelisted(lp1, false);
        assertEq(_redeemAllToCt(lp1), 100e6);
    }

    function test_vetroTreasury_receivesExtraAndIsRestricted() public {
        assertEq(vault.vetroTreasury(), vetroSafe);
        vm.prank(stranger);
        vm.expectRevert();
        vault.setVetroTreasury(stranger);
        vm.prank(vetroSafe);
        vm.expectRevert(ConcreteLPVault.AddressIsZero.selector);
        vault.setVetroTreasury(address(0));
    }

    function test_restricted() public {
        vm.startPrank(stranger);
        vm.expectRevert();
        vault.setWhitelisted(stranger, true);
        vm.expectRevert();
        vault.harvestExtraAssets();
        vm.stopPrank();
    }

    function test_sanctionedLpRefused() public {
        _sanction(lp1);
        ct.mint(lp1, 1e6);
        vm.startPrank(lp1);
        ct.approve(address(vault), 1e6);
        vm.expectRevert(abi.encodeWithSelector(Treasury.Sanctioned.selector, lp1));
        vault.deposit(1e6, lp1);
        vm.stopPrank();
    }

    function test_mintUnsupported() public {
        _depositCt(lp1, 100e6);
        assertEq(vault.maxMint(lp1), 0);
        vm.expectRevert(ConcreteLPVault.NotSupported.selector);
        vault.previewMint(1);
    }

    function test_shutdown_blocksExits() public {
        _depositCt(lp1, 100e6);
        vm.prank(concrete);
        spoke.setShutdown(true);
        assertEq(vault.maxRedeem(lp1), 0);
        assertEq(vault.maxWithdraw(lp1), 0);
    }

    /*/////////////////////////////////////////////////////////////
        DRIP EVERYTHING, LPS REDEEM AT CTDEFIUSDT VALUE
    /////////////////////////////////////////////////////////////*/

    /// @dev Core earns 20%, ctDefiUSDT 10%, 1M each. All harvested yield (core + spoke) is dripped to sVUSD; the vault
    /// redeems at ctDefiUSDT value and its extra is clawed back and dripped again. Concrete LPs end at exactly 10%,
    /// core stakers converge to their 20%.
    function test_dripAll_coreTwentyCtTen() public {
        _coreDeposit(alice, 1_000_000e6);
        vm.startPrank(alice);
        vusd.approve(address(svusd), type(uint256).max);
        svusd.deposit(1_000_000e18, alice);
        vm.stopPrank();
        _depositCt(lp1, 1_000_000e6);

        YieldDistributor _distributor = YieldDistributor(svusd.yieldDistributor());
        bytes32 _distributorRole = _distributor.DISTRIBUTOR_ROLE();
        vm.startPrank(admin);
        _distributor.grantRole(_distributorRole, address(this));
        manager.grantRole(VAULT_ROLE, address(this), 0);
        vm.stopPrank();
        vault.setVetroTreasury(address(this));

        uint256 _coreTvl = 1_000_000e18;
        uint256 _coreWeekly = _coreTvl * 2_000 / 10_000 / 52; // 3,846.15
        uint256 _aliceLast;
        for (uint256 w; w < 12; ++w) {
            uint256 _aliceBefore = svusd.previewRedeem(svusd.balanceOf(alice));
            ct.setRate(ct.rateWad() + ct.rateWad() * 1_000 / 10_000 / 52);
            deal(address(usdt), address(treasury), usdt.balanceOf(address(treasury)) + _coreWeekly / 1e12);
            _skip(7 days);
            _aliceLast = svusd.previewRedeem(svusd.balanceOf(alice)) - _aliceBefore;

            // Weekly batch: harvest every source to Vetro
            vm.startPrank(umm);
            gateway.harvest(address(0), address(this), type(uint256).max);
            gateway.harvest(address(spoke), address(this), type(uint256).max);
            vm.stopPrank();
            // Square the vault up: top up a shortfall, or claw the extra back as VUSD
            uint256 _short = vault.shortfallSVusd();
            if (_short > 0) {
                uint256 _vusd = svusd.previewMint(_short) + 1;
                vusd.approve(address(svusd), _vusd);
                svusd.deposit(_vusd, address(vault));
            } else {
                vault.harvestExtraAssets();
            }
            // Drip everything left, the clawed-back extra included
            uint256 _r = vusd.balanceOf(address(this));
            vusd.approve(address(_distributor), _r);
            _distributor.distribute(_r);

            assertEq(vault.previewRedeem(1_000_000e6), 1_000_000e6, "Concrete LPs: 1 ct per share every week");
        }
        assertApproxEqRel(_aliceLast, _coreWeekly, 0.01e18, "core stakers back at 20% (3,846/week)");

        uint256 _ctOut = _redeemAllToCt(lp1);
        assertEq(_ctOut, 1_000_000e6, "LP gets its ct back 1:1...");
        // ...worth (1 + 10%/52)^12 ≈ 1.0233 USDT each: 10% a year, nothing more
        assertApproxEqRel(_ctOut * ct.rateWad() / 1e18, 1_023_300e6, 0.0005e18, "ct yield only");
    }

    /*/////////////////////////////////////////////////////////////
        1M CORE AT 8%, 30M CONCRETE AT 6%: WEEKLY GROSS-UP DRIP
    /////////////////////////////////////////////////////////////*/

    /// @dev The drip is sized so core stakers earn the core rate: core weekly yield x total sVUSD / core sVUSD. The
    /// treasury funds the first drip once (the float); from then on the vault's extra, sent back to the treasury as
    /// VUSD each week (not burned), funds the next drip with the core and spoke harvest.
    function test_grossUp_oneMillionCoreThirtyMillionCt() public {
        vm.prank(admin);
        gateway.increaseSpokeMintLimit(address(spoke), 31_000_000e18);
        _coreDeposit(alice, 1_000_000e6);
        vm.startPrank(alice);
        vusd.approve(address(svusd), type(uint256).max);
        svusd.deposit(1_000_000e18, alice);
        vm.stopPrank();
        _depositCt(lp1, 30_000_000e6);

        YieldDistributor _distributor = YieldDistributor(svusd.yieldDistributor());
        bytes32 _distributorRole = _distributor.DISTRIBUTOR_ROLE();
        vm.startPrank(admin);
        _distributor.grantRole(_distributorRole, address(this));
        manager.grantRole(VAULT_ROLE, address(this), 0);
        vm.stopPrank();
        vault.setVetroTreasury(address(this));

        uint256 _coreTvl = 1_000_000e18;
        uint256 _coreWeekly = _coreTvl * 800 / 10_000 / 52; // 1,538.46
        uint256 _floatUsed;
        uint256 _floatAfterWeekOne;
        for (uint256 w; w < 6; ++w) {
            uint256 _aliceBefore = svusd.previewRedeem(svusd.balanceOf(alice));
            ct.setRate(ct.rateWad() + ct.rateWad() * 600 / 10_000 / 52);
            deal(address(usdt), address(treasury), usdt.balanceOf(address(treasury)) + _coreWeekly / 1e12);
            _skip(7 days);
            uint256 _aliceGot = svusd.previewRedeem(svusd.balanceOf(alice)) - _aliceBefore;

            // Weekly batch: harvest core and spoke, square the vault up, drip the gross-up target
            vm.startPrank(umm);
            uint256 _core = gateway.harvest(address(0), address(this), type(uint256).max);
            gateway.harvest(address(spoke), address(this), type(uint256).max);
            vm.stopPrank();
            uint256 _extra;
            uint256 _short = vault.shortfallSVusd();
            if (_short > 0) {
                uint256 _vusd = svusd.previewMint(_short) + 1;
                vusd.approve(address(svusd), _vusd);
                svusd.deposit(_vusd, address(vault));
            } else {
                (, _extra) = vault.harvestExtraAssets();
            }
            uint256 _target = _core * svusd.totalSupply() / svusd.balanceOf(alice);
            uint256 _held = vusd.balanceOf(address(this));
            if (_held < _target) {
                // The treasury adds the float
                uint256 _add = _target - _held;
                _coreDeposit(address(this), _add / 1e12 + 1);
                _floatUsed += _add;
            }
            vusd.approve(address(_distributor), _target);
            _distributor.distribute(_target);

            if (w == 0) {
                _floatAfterWeekOne = _floatUsed;
                assertApproxEqRel(_floatUsed, 46_154e18, 0.01e18, "one-time float ~ core weekly x 30");
            } else {
                assertApproxEqRel(_aliceGot, _coreWeekly, 0.01e18, "core stakers earn their 8%");
                assertApproxEqRel(_extra, 11_538e18, 0.03e18, "~11.5k VUSD back to the treasury each week");
                assertEq(_floatUsed, _floatAfterWeekOne, "no new treasury money after week 1");
            }
            assertEq(vault.previewRedeem(30_000_000e6), 30_000_000e6, "ct LPs: 1 ct per share every week");
        }
        assertEq(_redeemAllToCt(lp1), 30_000_000e6);
    }
}

/// @dev Weekly Safe flow with rates changing every week: the vault always squares up to 1 ct per share
contract ConcreteLPVaultFlowTest is ConcreteLPVaultTest {
    uint256[6] ctAprBps = [uint256(1_000), 400, 800, 200, 1_200, 600];
    uint256[6] dripBps = [uint256(700), 700, 500, 900, 300, 700];

    function test_flow_weeklySquareUp() public {
        _depositCt(lp1, 1_000_000e6);
        for (uint256 w; w < 6; ++w) {
            ct.setRate(ct.rateWad() + ct.rateWad() * ctAprBps[w] / 10_000 / 52);
            _drip(svusd.totalAssets() * dripBps[w] / 10_000 / 52);
            _harvestSpoke();
            if (vault.shortfallSVusd() > 0) {
                _topUp();
            } else {
                vm.prank(vetroSafe);
                vault.harvestExtraAssets();
            }
            assertEq(vault.shortfallSVusd(), 0, "squared up");
            assertEq(vault.previewRedeem(1_000_000e6), 1_000_000e6, "1 ct per share");
        }
        assertEq(_redeemAllToCt(lp1), 1_000_000e6);
    }
}
