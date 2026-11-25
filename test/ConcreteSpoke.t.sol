// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ConcreteSpoke} from "src/ConcreteSpoke.sol";
import {Gateway} from "src/Gateway.sol";
import {PeggedToken} from "src/PeggedToken.sol";
import {StakingVault} from "src/StakingVault.sol";
import {Treasury} from "src/Treasury.sol";
import {YieldDistributor} from "src/YieldDistributor.sol";
import {YieldManager} from "src/YieldManager.sol";
import {IPeggedToken} from "src/interfaces/IPeggedToken.sol";
import {IYieldDistributor} from "src/interfaces/IYieldDistributor.sol";
import {deployTreasury} from "test/helpers/Deploy.sol";
import {MockChainlinkOracle} from "test/mocks/MockChainlinkOracle.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockRateVault} from "test/mocks/MockRateVault.sol";
import {MockSanctionsList} from "test/mocks/MockSanctionsList.sol";
import {MockYieldVault} from "test/mocks/MockYieldVault.sol";

/// @dev Records what a ctDefiUSDT transfer hook would see of the spoke
contract ReserveProbe {
    uint256 public reserve;
    uint256 public supply;

    function record(ConcreteSpoke spoke_, Gateway gateway_) external {
        reserve = spoke_.reserve();
        supply = gateway_.spokeSupply(address(spoke_));
    }
}

/// @dev One Concrete spoke (ctDefiUSDT) next to the core Treasury (USDT), permissioned by an AccessManager, with two
/// whitelisted LPs
abstract contract ConcreteSpokeBase is Test {
    PeggedToken vusd;
    Treasury treasury;
    Gateway gateway;
    StakingVault svusd;
    YieldManager yieldManager;
    AccessManager manager;
    ConcreteSpoke spoke;

    MockERC20 usdt; // core collateral, also the share's underlying
    MockYieldVault coreVault;
    MockChainlinkOracle usdtOracle; // the Treasury's USDT feed, also the spoke's mint check
    MockRateVault ct; // ctDefiUSDT

    address admin = makeAddr("admin"); // Vetro Safe: Treasury and Gateway admin, AccessManager admin
    address vetro = makeAddr("vetro"); // whitelist (delayed)
    address concrete = makeAddr("concrete"); // shutdown and force exit
    address keeper = makeAddr("keeper");
    address umm = makeAddr("umm");
    address alice = makeAddr("alice"); // core holder
    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");
    address stranger = makeAddr("stranger");

    uint64 constant WHITELIST_ROLE = 1;
    uint64 constant CONCRETE_ROLE = 3;
    uint32 constant DELAY = 3 days;
    uint256 constant LIMIT = 10_000_000e18;

    function setUp() public virtual {
        vusd = new PeggedToken("VUSD", "VUSD", address(this));
        treasury = deployTreasury(address(vusd), admin);
        vusd.updateTreasury(address(treasury));

        bytes memory _gatewayInit = abi.encodeCall(Gateway.initialize, (address(vusd), type(uint256).max, 7 days));
        gateway = Gateway(address(new ERC1967Proxy(address(new Gateway()), _gatewayInit)));
        vusd.updateGateway(address(gateway));

        usdt = new MockERC20();
        coreVault = new MockYieldVault(address(usdt));
        usdtOracle = new MockChainlinkOracle(1e8);
        ct = new MockRateVault(address(usdt));
        _deployStaking();

        vm.startPrank(admin);
        treasury.addToWhitelist(address(usdt), address(coreVault), address(usdtOracle), 1 days);
        treasury.grantRole(treasury.MAINTAINER_ROLE(), address(this));
        treasury.grantRole(treasury.UMM_ROLE(), umm);
        treasury.grantRole(treasury.UMM_ROLE(), address(yieldManager));
        treasury.grantRole(treasury.KEEPER_ROLE(), keeper);
        vm.stopPrank();
        gateway.addToInstantRedeemWhitelist(alice);
        gateway.addToInstantRedeemWhitelist(lp1);
        gateway.addToInstantRedeemWhitelist(lp2);

        manager = new AccessManager(admin);
        spoke = _deploySpoke(ct);
        _addSpoke(spoke);
        _whitelist(spoke, lp1);
        _whitelist(spoke, lp2);
    }

    /*/////////////////////////////////////////////////////////////
                            HELPERS
    /////////////////////////////////////////////////////////////*/

    function _deployStaking() internal {
        svusd = StakingVault(
            address(
                new ERC1967Proxy(
                    address(new StakingVault()),
                    abi.encodeCall(StakingVault.initialize, (address(vusd), "Staked VUSD", "sVUSD", address(this)))
                )
            )
        );
        YieldDistributor _distributor = YieldDistributor(
            address(
                new ERC1967Proxy(
                    address(new YieldDistributor()),
                    abi.encodeCall(YieldDistributor.initialize, (address(vusd), address(svusd), admin))
                )
            )
        );
        svusd.updateYieldDistributor(address(_distributor));
        yieldManager = new YieldManager(
            IPeggedToken(address(vusd)), IYieldDistributor(address(_distributor)), 1_500, 1_000_000e18
        );
        vm.startPrank(admin);
        _distributor.grantRole(_distributor.DISTRIBUTOR_ROLE(), address(yieldManager));
        vm.stopPrank();
    }

    function _deploySpoke(MockRateVault asset_) internal returns (ConcreteSpoke _spoke) {
        bytes memory _init = abi.encodeCall(
            ConcreteSpoke.initialize, (address(manager), address(vusd), address(asset_), address(svusd))
        );
        _spoke = ConcreteSpoke(address(new ERC1967Proxy(address(new ConcreteSpoke()), _init)));
        // The AccessManager setup a deployment expects: the whitelist behind a delay, Concrete shuts down and force
        // exits at once
        bytes4[] memory _whitelistSelectors = new bytes4[](1);
        _whitelistSelectors[0] = ConcreteSpoke.setWhitelisted.selector;
        bytes4[] memory _concreteSelectors = new bytes4[](3);
        _concreteSelectors[0] = ConcreteSpoke.setShutdown.selector;
        _concreteSelectors[1] = ConcreteSpoke.forceRedeem.selector;
        _concreteSelectors[2] = ConcreteSpoke.forceUnstakeAndRedeem.selector;
        vm.startPrank(admin);
        manager.setTargetFunctionRole(address(_spoke), _whitelistSelectors, WHITELIST_ROLE);
        manager.setTargetFunctionRole(address(_spoke), _concreteSelectors, CONCRETE_ROLE);
        manager.grantRole(WHITELIST_ROLE, vetro, DELAY);
        manager.grantRole(CONCRETE_ROLE, concrete, 0);
        vm.stopPrank();
        // The staked exit unstakes as the spoke, which needs the instant withdraw whitelist
        svusd.updateInstantWithdrawWhitelist(address(_spoke), true);
    }

    function _addSpoke(ConcreteSpoke spoke_) internal {
        vm.startPrank(admin);
        gateway.addSpoke(address(spoke_));
        gateway.increaseSpokeMintLimit(address(spoke_), LIMIT);
        vm.stopPrank();
    }

    /// @dev Schedules the whitelist change, waits out the delay, then executes it
    function _whitelist(ConcreteSpoke spoke_, address account_) internal {
        bytes memory _data = abi.encodeCall(ConcreteSpoke.setWhitelisted, (account_, true));
        vm.prank(vetro);
        manager.schedule(address(spoke_), _data, 0);
        _skip(DELAY);
        vm.prank(vetro);
        manager.execute(address(spoke_), _data);
    }

    function _coreDeposit(address who_, uint256 usdtAmount_) internal returns (uint256 _minted) {
        deal(address(usdt), who_, usdtAmount_);
        vm.startPrank(who_);
        usdt.approve(address(gateway), usdtAmount_);
        _minted = gateway.deposit(address(usdt), usdtAmount_, 0, who_);
        vm.stopPrank();
    }

    /// @dev Leaves the prank on `lp_` running
    function _fundAndApprove(address lp_, uint256 shares_) internal {
        ct.mint(lp_, shares_);
        vm.startPrank(lp_);
        ct.approve(address(spoke), shares_);
    }

    function _mint(address lp_, uint256 shares_) internal returns (uint256 _minted) {
        _fundAndApprove(lp_, shares_);
        _minted = spoke.mint(shares_, 0, lp_);
        vm.stopPrank();
    }

    function _redeem(address lp_, uint256 vusdAmount_) internal returns (uint256 _shares) {
        vm.prank(lp_);
        _shares = spoke.redeem(vusdAmount_, 0, lp_);
    }

    function _sanction(address account_) internal {
        MockSanctionsList _sanctions = new MockSanctionsList();
        vm.prank(admin);
        treasury.updateSanctionsList(address(_sanctions));
        _sanctions.setSanctioned(account_, true);
    }

    /// @dev Move time and refresh the price feed, as keepers would on mainnet
    function _skip(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
        usdtOracle.updatePrice(1e8);
    }

    /// @dev UMM harvests all of a source's yield (`address(0)` for the core) to itself
    function _harvest(address source_) internal returns (uint256) {
        vm.prank(umm);
        return gateway.harvest(source_, umm, type(uint256).max);
    }

    /// @dev Harvests the surplus (core and spoke) and streams it to sVUSD over the full yield duration
    function _streamToStakers() internal {
        vm.startPrank(umm);
        uint256 _amount = gateway.harvest(address(0), address(this), type(uint256).max)
            + gateway.harvest(address(spoke), address(this), type(uint256).max);
        vm.stopPrank();
        YieldDistributor _distributor = YieldDistributor(svusd.yieldDistributor());
        vm.startPrank(admin);
        _distributor.grantRole(_distributor.DISTRIBUTOR_ROLE(), address(this));
        vm.stopPrank();
        vusd.approve(address(_distributor), _amount);
        _distributor.distribute(_amount);
        _skip(_distributor.DEFAULT_YIELD_DURATION());
    }
}

contract ConcreteSpokeTest is ConcreteSpokeBase {
    /*/////////////////////////////////////////////////////////////
                            MINT
    /////////////////////////////////////////////////////////////*/

    function test_mint_atSharePriceTracksSupply() public {
        ct.setRate(1.05e18);
        assertEq(spoke.previewMint(100e6), 105e18);
        uint256 _minted = _mint(lp1, 100e6);

        assertEq(_minted, 105e18, "1 VUSD per 1 USDT of shares");
        assertEq(vusd.balanceOf(lp1), 105e18);
        assertEq(gateway.spokeSupply(address(spoke)), 105e18);
        assertEq(gateway.totalSpokeSupply(), 105e18);
        assertEq(gateway.coreSupply(), 0, "spoke supply is not core");
        assertEq(ct.balanceOf(address(spoke)), 100e6, "spoke holds the shares");
        assertEq(spoke.reserve(), 105e18);
    }

    function test_mint_revertIfCallerOrReceiverNotWhitelisted() public {
        _fundAndApprove(stranger, 100e6);
        vm.expectRevert(abi.encodeWithSelector(ConcreteSpoke.NotWhitelisted.selector, stranger));
        spoke.mint(100e6, 0, stranger);
        vm.stopPrank();

        _fundAndApprove(lp1, 100e6);
        vm.expectRevert(abi.encodeWithSelector(ConcreteSpoke.NotWhitelisted.selector, stranger));
        spoke.mint(100e6, 0, stranger);
        vm.stopPrank();
    }

    function test_mint_revertAboveMintLimit() public {
        vm.prank(admin);
        gateway.decreaseSpokeMintLimit(address(spoke), 50e18);
        assertEq(spoke.maxMint(), 50e18);

        _fundAndApprove(lp1, 100e6);
        vm.expectRevert(abi.encodeWithSelector(Gateway.ExceededMaxMint.selector, 100e18, 50e18));
        spoke.mint(100e6, 0, lp1);
        vm.stopPrank();
    }

    function test_mint_doesNotUseCoreMintLimit() public {
        vm.prank(admin);
        gateway.updateMintLimit(0);
        assertEq(_mint(lp1, 100e6), 100e18);
        assertEq(gateway.maxMint(), 0, "core limit untouched by spoke supply");
    }

    function test_mint_slippage() public {
        _fundAndApprove(lp1, 100e6);
        vm.expectRevert(abi.encodeWithSelector(ConcreteSpoke.MintableIsLessThanMinimum.selector, 100e18, 100e18 + 1));
        spoke.mint(100e6, 100e18 + 1, lp1);
        vm.stopPrank();
    }

    /// @dev 1:1 both ways: no USDT price is read, so neither a depeg nor a stale feed moves or stops spoke mints
    function test_mint_ignoresUsdtPrice() public {
        usdtOracle.updatePrice(0.95e8);
        assertEq(_mint(lp1, 100e6), 100e18, "par below peg");
        usdtOracle.updatePrice(1.05e8);
        assertEq(_mint(lp1, 100e6), 100e18, "par above peg");
        vm.warp(block.timestamp + 7 days); // stale feed
        assertEq(spoke.maxMint(), LIMIT - 200e18);
        assertEq(_mint(lp1, 100e6), 100e18, "stale feed");
        assertEq(_redeem(lp1, 300e18), 300e6);
    }

    function test_mint_revertIfTransferHookSkims() public {
        ct.setHook(MockRateVault.Hook.Skim, stranger, "");
        _fundAndApprove(lp1, 100e6);
        vm.expectRevert(abi.encodeWithSelector(ConcreteSpoke.FeeOnTransferToken.selector, address(ct)));
        spoke.mint(100e6, 0, lp1);
        vm.stopPrank();
    }

    function test_mintAndStake_receiverGetsSvusd() public {
        ct.setRate(1.05e18);
        _fundAndApprove(lp1, 100e6);
        uint256 _expected = spoke.previewMintAndStake(100e6);
        uint256 _shares = spoke.mintAndStake(100e6, _expected, lp2);
        vm.stopPrank();

        assertEq(_shares, _expected);
        assertEq(svusd.balanceOf(lp2), _shares);
        assertEq(vusd.balanceOf(address(spoke)), 0, "nothing left in the spoke");
        assertEq(svusd.totalAssets(), 105e18);
        assertEq(gateway.spokeSupply(address(spoke)), 105e18);
    }

    function test_mintAndStake_revertIfReceiverNotWhitelisted() public {
        _fundAndApprove(lp1, 100e6);
        vm.expectRevert(abi.encodeWithSelector(ConcreteSpoke.NotWhitelisted.selector, stranger));
        spoke.mintAndStake(100e6, 0, stranger);
        vm.stopPrank();
    }

    /*/////////////////////////////////////////////////////////////
                            REDEEM
    /////////////////////////////////////////////////////////////*/

    function test_redeem_instantAtSharePrice() public {
        _mint(lp1, 100e6);
        assertTrue(gateway.withdrawalDelayEnabled(), "core delay is on");

        ct.setRate(1.1e18);
        assertEq(spoke.previewRedeem(55e18), 50e6);
        uint256 _shares = _redeem(lp1, 55e18);

        assertEq(_shares, 50e6, "55 VUSD buys 50 shares at 1.10");
        assertEq(ct.balanceOf(lp1), 50e6);
        assertEq(gateway.spokeSupply(address(spoke)), 45e18);
        assertEq(vusd.balanceOf(lp1), 45e18);
    }

    function test_redeem_revertIfNotWhitelisted() public {
        _mint(lp1, 100e6);
        vm.prank(lp1);
        vusd.transfer(stranger, 10e18);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ConcreteSpoke.NotWhitelisted.selector, stranger));
        spoke.redeem(10e18, 0, stranger);
    }

    function test_redeem_revertAboveSpokeSupply() public {
        _mint(lp1, 100e6);
        _coreDeposit(alice, 50e6);
        vm.prank(alice);
        vusd.transfer(lp1, 50e18);
        // Extra shares in the spoke so the supply check, not the balance, binds
        ct.mint(address(spoke), 50e6);

        vm.prank(lp1);
        vm.expectRevert(abi.encodeWithSelector(Gateway.ExceededSpokeSupply.selector, 150e18, 100e18));
        spoke.redeem(150e18, 0, lp1);
    }

    function test_redeem_slippage() public {
        _mint(lp1, 100e6);
        vm.prank(lp1);
        vm.expectRevert(abi.encodeWithSelector(ConcreteSpoke.RedeemableIsLessThanMinimum.selector, 50e6, 51e6));
        spoke.redeem(50e18, 51e6, lp1);
    }

    /// @dev A ctDefiUSDT pre-transfer hook never sees the reserve overstated: the shares go out before the burn
    function test_redeem_transferHookNeverSeesReserveOverstated() public {
        _mint(lp1, 100e6);
        ReserveProbe _probe = new ReserveProbe();
        ct.setHook(MockRateVault.Hook.Call, address(_probe), abi.encodeCall(ReserveProbe.record, (spoke, gateway)));

        assertEq(_redeem(lp1, 50e18), 50e6);
        assertLe(_probe.reserve(), _probe.supply(), "mid-redeem reserve not above supply");
        assertEq(gateway.spokeSupply(address(spoke)), 50e18);
        assertEq(spoke.reserve(), 50e18);
    }

    function test_redeem_blockedTransferBurnsNothing() public {
        _mint(lp1, 100e6);
        ct.setHook(MockRateVault.Hook.Block, address(0), "");
        vm.prank(lp1);
        vm.expectRevert(MockRateVault.TransferBlocked.selector);
        spoke.redeem(50e18, 0, lp1);
        assertEq(vusd.balanceOf(lp1), 100e18);
        assertEq(gateway.spokeSupply(address(spoke)), 100e18);
    }

    /// @dev Below one share unit a redeem would burn VUSD and pay nothing
    function test_redeem_revertForDust() public {
        _mint(lp1, 100e6);
        ct.setRate(1.08e18);
        vm.prank(lp1);
        vm.expectRevert(ConcreteSpoke.AmountIsZero.selector);
        spoke.redeem(1e12, 0, lp1);
    }

    function test_unstakeAndRedeem_instantDespiteCooldown() public {
        _fundAndApprove(lp1, 100e6);
        uint256 _shares = spoke.mintAndStake(100e6, 0, lp1);
        vm.stopPrank();
        assertTrue(svusd.cooldownEnabled());
        assertFalse(svusd.instantWithdrawWhitelist(lp1), "the LP needs no staking whitelist entry");

        uint256 _expected = spoke.previewUnstakeAndRedeem(_shares);
        vm.startPrank(lp1);
        svusd.approve(address(spoke), _shares);
        uint256 _out = spoke.unstakeAndRedeem(_shares, _expected, lp1);
        vm.stopPrank();

        assertEq(_out, 100e6);
        assertEq(_out, _expected);
        assertEq(ct.balanceOf(lp1), 100e6);
        assertEq(svusd.balanceOf(lp1), 0);
        assertEq(gateway.spokeSupply(address(spoke)), 0);
    }

    /// @dev Removing the spoke from the staking vault's instant whitelist closes the staked exit (a StakingVault owner
    /// lever); the plain VUSD exit stays open
    function test_unstakeAndRedeem_needsSpokeOnInstantWhitelist() public {
        _fundAndApprove(lp1, 100e6);
        uint256 _shares = spoke.mintAndStake(100e6, 0, lp1);
        svusd.approve(address(spoke), _shares);
        vm.stopPrank();
        svusd.updateInstantWithdrawWhitelist(address(spoke), false);

        vm.prank(lp1);
        vm.expectRevert(StakingVault.CooldownEnabled.selector);
        spoke.unstakeAndRedeem(_shares, 0, lp1);
    }

    function test_unstakeAndRedeem_revertIfZeroNotWhitelistedOrSanctioned() public {
        _fundAndApprove(lp1, 100e6);
        uint256 _shares = spoke.mintAndStake(100e6, 0, lp1);
        svusd.transfer(stranger, _shares / 4);
        svusd.approve(address(spoke), type(uint256).max);
        vm.expectRevert(ConcreteSpoke.AmountIsZero.selector);
        spoke.unstakeAndRedeem(0, 0, lp1);
        vm.stopPrank();

        vm.startPrank(stranger);
        svusd.approve(address(spoke), _shares / 4);
        vm.expectRevert(abi.encodeWithSelector(ConcreteSpoke.NotWhitelisted.selector, stranger));
        spoke.unstakeAndRedeem(_shares / 4, 0, stranger);
        vm.stopPrank();

        _sanction(lp2);
        vm.prank(lp1);
        vm.expectRevert(abi.encodeWithSelector(Treasury.Sanctioned.selector, lp2));
        spoke.unstakeAndRedeem(_shares / 4, 0, lp2);

        _sanction(lp1);
        vm.prank(lp1);
        vm.expectRevert(abi.encodeWithSelector(Treasury.Sanctioned.selector, lp1));
        spoke.unstakeAndRedeem(_shares / 4, 0, lp1);
    }

    /// @dev Staking yield from the spoke's own harvest exits in full; yield from the core can push a staked exit past
    /// the spoke's supply, which is refused (that VUSD exits through the core)
    function test_unstakeAndRedeem_withStakingYield() public {
        _fundAndApprove(lp1, 100e6);
        uint256 _shares = spoke.mintAndStake(100e6, 0, lp1);
        svusd.approve(address(spoke), _shares);
        vm.stopPrank();

        ct.setRate(1.1e18);
        _streamToStakers();
        uint256 _expected = spoke.previewUnstakeAndRedeem(_shares / 2);
        vm.prank(lp1);
        assertEq(spoke.unstakeAndRedeem(_shares / 2, _expected, lp1), _expected, "preview equals execution");
        assertApproxEqAbs(_expected, 50e6, 1, "half of 110 VUSD at 1.10");

        _coreDeposit(alice, 1_000e6);
        deal(address(usdt), address(treasury), usdt.balanceOf(address(treasury)) + 100e6); // core yield
        _streamToStakers();
        uint256 _rest = svusd.balanceOf(lp1);
        assertGt(svusd.previewRedeem(_rest), gateway.spokeSupply(address(spoke)));
        // The spoke lacks the shares, so the payout fails before the Gateway's supply check would
        vm.prank(lp1);
        vm.expectRevert();
        spoke.unstakeAndRedeem(_rest, 0, lp1);
    }

    /*/////////////////////////////////////////////////////////////
                            SHUTDOWN
    /////////////////////////////////////////////////////////////*/

    function test_setShutdown_concreteStopsEverythingAndReopens() public {
        _mint(lp1, 100e6);
        vm.prank(concrete);
        spoke.setShutdown(true);
        assertTrue(spoke.shutdown());
        assertEq(spoke.maxMint(), 0);
        assertEq(spoke.maxRedeem(lp1), 0);

        _fundAndApprove(lp1, 1e6);
        vm.expectRevert(ConcreteSpoke.SpokeIsShutdown.selector);
        spoke.mint(1e6, 0, lp1);
        vm.expectRevert(ConcreteSpoke.SpokeIsShutdown.selector);
        spoke.redeem(10e18, 0, lp1);
        vm.stopPrank();
        vm.prank(concrete);
        vm.expectRevert(ConcreteSpoke.SpokeIsShutdown.selector);
        spoke.forceRedeem(lp1, 10e18, 0);

        vm.prank(concrete);
        spoke.setShutdown(false);
        assertEq(_redeem(lp1, 100e18), 100e6);
    }

    /// @dev Only Concrete shuts the spoke down; Vetro stops mints through the Gateway limit, never exits
    function test_shutdown_heldByConcreteOnly() public {
        vm.prank(vetro);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, vetro));
        spoke.setShutdown(true);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, admin));
        spoke.setShutdown(true);
    }

    /*/////////////////////////////////////////////////////////////
                            FORCE EXIT
    /////////////////////////////////////////////////////////////*/

    function test_forceRedeem_paysLpOwnWalletWithoutApproval() public {
        _mint(lp1, 1_000e6);

        vm.prank(concrete);
        uint256 _shares = spoke.forceRedeem(lp1, 400e18, 0);

        assertEq(_shares, 400e6);
        assertEq(ct.balanceOf(lp1), 400e6, "paid to the LP");
        assertEq(ct.balanceOf(concrete), 0);
        assertEq(vusd.balanceOf(lp1), 600e18);
        assertEq(gateway.spokeSupply(address(spoke)), 600e18);
    }

    function test_forceRedeem_revertIfNotConcreteOrNotWhitelisted() public {
        _mint(lp1, 1_000e6);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        spoke.forceRedeem(lp1, 1e18, 0);

        _coreDeposit(alice, 10e6);
        vm.prank(concrete);
        vm.expectRevert(abi.encodeWithSelector(ConcreteSpoke.NotWhitelisted.selector, alice));
        spoke.forceRedeem(alice, 1e18, 0);
    }

    function test_forceRedeem_revertIfSanctioned() public {
        _mint(lp1, 100e6);
        _sanction(lp1);
        vm.prank(concrete);
        vm.expectRevert(abi.encodeWithSelector(Treasury.Sanctioned.selector, lp1));
        spoke.forceRedeem(lp1, 100e18, 0);
    }

    function test_forceUnstakeAndRedeem_paysLpOwnWalletWithAllowance() public {
        _fundAndApprove(lp1, 100e6);
        uint256 _shares = spoke.mintAndStake(100e6, 0, lp1);
        svusd.approve(address(spoke), type(uint256).max); // kept under the LP agreement
        vm.stopPrank();

        uint256 _expected = spoke.previewUnstakeAndRedeem(_shares);
        vm.prank(concrete);
        assertEq(spoke.forceUnstakeAndRedeem(lp1, _shares, _expected), 100e6);
        assertEq(ct.balanceOf(lp1), 100e6, "paid to the LP's own wallet");
        assertEq(svusd.balanceOf(lp1), 0);
        assertEq(gateway.spokeSupply(address(spoke)), 0);
    }

    function test_forceUnstakeAndRedeem_revertIfNotConcreteNotWhitelistedNoAllowanceOrSanctioned() public {
        _fundAndApprove(lp1, 100e6);
        uint256 _shares = spoke.mintAndStake(100e6, 0, lp1);
        svusd.transfer(stranger, _shares / 4);
        vm.stopPrank();

        vm.prank(vetro);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, vetro));
        spoke.forceUnstakeAndRedeem(lp1, _shares / 4, 0);

        vm.prank(stranger);
        svusd.approve(address(spoke), _shares / 4);
        vm.prank(concrete);
        vm.expectRevert(abi.encodeWithSelector(ConcreteSpoke.NotWhitelisted.selector, stranger));
        spoke.forceUnstakeAndRedeem(stranger, _shares / 4, 0);

        // No allowance: the LP has to have approved the spoke
        vm.prank(concrete);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientAllowance(address,uint256,uint256)", address(spoke), 0, _shares / 4
            )
        );
        spoke.forceUnstakeAndRedeem(lp1, _shares / 4, 0);

        vm.prank(lp1);
        svusd.approve(address(spoke), type(uint256).max);
        _sanction(lp1);
        vm.prank(concrete);
        vm.expectRevert(abi.encodeWithSelector(Treasury.Sanctioned.selector, lp1));
        spoke.forceUnstakeAndRedeem(lp1, _shares / 4, 0);
    }

    /*/////////////////////////////////////////////////////////////
                            WHITELIST
    /////////////////////////////////////////////////////////////*/

    function test_setWhitelisted_waitsOutTheDelay() public {
        bytes memory _data = abi.encodeCall(ConcreteSpoke.setWhitelisted, (stranger, true));
        bytes32 _op = manager.hashOperation(vetro, address(spoke), _data);
        vm.prank(vetro);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, _op));
        spoke.setWhitelisted(stranger, true);

        vm.prank(vetro);
        manager.schedule(address(spoke), _data, 0);
        _skip(DELAY - 1);
        vm.prank(vetro);
        vm.expectRevert();
        manager.execute(address(spoke), _data);

        _skip(1);
        vm.prank(vetro);
        spoke.setWhitelisted(stranger, true);
        assertTrue(spoke.isWhitelisted(stranger));
    }

    function test_setWhitelisted_removalAlsoWaits() public {
        vm.prank(vetro);
        vm.expectRevert();
        spoke.setWhitelisted(lp1, false);
        assertTrue(spoke.isWhitelisted(lp1));

        bytes memory _data = abi.encodeCall(ConcreteSpoke.setWhitelisted, (lp1, false));
        vm.prank(vetro);
        manager.schedule(address(spoke), _data, 0);
        _skip(DELAY);
        vm.prank(vetro);
        manager.execute(address(spoke), _data);
        assertFalse(spoke.isWhitelisted(lp1));
        assertEq(spoke.getWhitelist().length, 1);
    }

    /*/////////////////////////////////////////////////////////////
                            SANCTIONS
    /////////////////////////////////////////////////////////////*/

    function test_mintAndRedeem_revertIfSanctioned() public {
        _mint(lp1, 100e6);
        _mint(lp2, 10e6);
        _sanction(lp1);

        _fundAndApprove(lp1, 10e6);
        vm.expectRevert(abi.encodeWithSelector(Treasury.Sanctioned.selector, lp1));
        spoke.mint(10e6, 0, lp1);
        vm.expectRevert(abi.encodeWithSelector(Treasury.Sanctioned.selector, lp1));
        spoke.redeem(10e18, 0, lp1);
        vm.stopPrank();

        // A sanctioned receiver is refused too
        vm.prank(lp2);
        vm.expectRevert(abi.encodeWithSelector(Treasury.Sanctioned.selector, lp1));
        spoke.redeem(1e18, 0, lp1);

        // A sanctioned payer cannot mint to a clean receiver, as at the core, nor stake for one
        _fundAndApprove(lp1, 10e6);
        vm.expectRevert(abi.encodeWithSelector(Treasury.Sanctioned.selector, lp1));
        spoke.mint(10e6, 0, lp2);
        vm.expectRevert(abi.encodeWithSelector(Treasury.Sanctioned.selector, lp1));
        spoke.mintAndStake(10e6, 0, lp2);
        vm.stopPrank();

        // A clean payer cannot mint to a sanctioned receiver; staked, sVUSD refuses the deposit for them
        _fundAndApprove(lp2, 10e6);
        vm.expectRevert(abi.encodeWithSelector(Treasury.Sanctioned.selector, lp1));
        spoke.mint(10e6, 0, lp1);
        vm.expectRevert(abi.encodeWithSignature("ERC4626ExceededMaxDeposit(address,uint256,uint256)", lp1, 10e18, 0));
        spoke.mintAndStake(10e6, 0, lp1);
        vm.stopPrank();
    }

    /*/////////////////////////////////////////////////////////////
                    GATEWAY: SPOKE LEDGER
    /////////////////////////////////////////////////////////////*/

    function test_mintAndBurnFromSpoke_onlySpoke() public {
        vm.expectRevert(abi.encodeWithSelector(Gateway.CallerNotSpoke.selector, address(this)));
        gateway.mintFromSpoke(address(this), address(this), 1e18);
        vm.expectRevert(abi.encodeWithSelector(Gateway.CallerNotSpoke.selector, address(this)));
        gateway.burnFromSpoke(lp1, lp1, 1e18);
    }

    function test_spokeMintLimit_increaseAndDecreaseOnly() public {
        bytes32 _adminRole = gateway.DEFAULT_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Gateway.AccessControlUnauthorizedAccount.selector, stranger, _adminRole));
        gateway.increaseSpokeMintLimit(address(spoke), LIMIT + 1);

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(Gateway.InvalidSpokeMintLimit.selector, LIMIT, LIMIT));
        gateway.increaseSpokeMintLimit(address(spoke), LIMIT);
        vm.expectRevert(abi.encodeWithSelector(Gateway.InvalidSpokeMintLimit.selector, LIMIT, LIMIT));
        gateway.decreaseSpokeMintLimit(address(spoke), LIMIT);
        vm.expectRevert(abi.encodeWithSelector(Gateway.InvalidSpoke.selector, stranger));
        gateway.increaseSpokeMintLimit(stranger, 1);

        vm.expectEmit(address(gateway));
        emit Gateway.SpokeMintLimitUpdated(address(spoke), LIMIT, 2 * LIMIT);
        gateway.increaseSpokeMintLimit(address(spoke), 2 * LIMIT);
        gateway.decreaseSpokeMintLimit(address(spoke), 1);
        vm.stopPrank();
        assertEq(gateway.spokeMintLimit(address(spoke)), 1);
    }

    /// @dev Vetro's mint stop on the Gateway side: a limit at or below supply blocks mints and never exits
    function test_decreaseLimitToZero_stopsMintsKeepsRedeems() public {
        _mint(lp1, 100e6);
        vm.prank(admin);
        gateway.decreaseSpokeMintLimit(address(spoke), 0);
        assertEq(spoke.maxMint(), 0);

        _fundAndApprove(lp1, 1e6);
        vm.expectRevert(abi.encodeWithSelector(Gateway.ExceededMaxMint.selector, 1e18, 0));
        spoke.mint(1e6, 0, lp1);
        vm.stopPrank();
        assertEq(_redeem(lp1, 100e18), 100e6);
    }

    function test_addSpoke_rejectsZeroDuplicateAndOtherPeggedToken() public {
        vm.startPrank(admin);
        vm.expectRevert(Gateway.AddressIsZero.selector);
        gateway.addSpoke(address(0));
        vm.expectRevert(abi.encodeWithSelector(Gateway.InvalidSpoke.selector, address(spoke)));
        gateway.addSpoke(address(spoke));
        vm.stopPrank();

        PeggedToken _other = new PeggedToken("OTHER", "OTHER", address(this));
        bytes memory _init =
            abi.encodeCall(ConcreteSpoke.initialize, (address(manager), address(_other), address(ct), address(svusd)));
        address _impl = address(new ConcreteSpoke());
        vm.expectRevert(abi.encodeWithSelector(ConcreteSpoke.InvalidStakingVault.selector, address(svusd)));
        new ERC1967Proxy(_impl, _init);
    }

    function test_removeSpoke_onlyAtZeroSupplyAndClearsLimit() public {
        _mint(lp1, 100e6);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Gateway.SpokeSupplyNotZero.selector, address(spoke), 100e18));
        gateway.removeSpoke(address(spoke));

        _redeem(lp1, 100e18);
        vm.prank(admin);
        gateway.removeSpoke(address(spoke));
        assertEq(gateway.getSpokes().length, 0);
        assertEq(gateway.spokeMintLimit(address(spoke)), 0);

        // A removed spoke can no longer mint
        _fundAndApprove(lp1, 1e6);
        vm.expectRevert(abi.encodeWithSelector(Gateway.CallerNotSpoke.selector, address(spoke)));
        spoke.mint(1e6, 0, lp1);
        vm.stopPrank();
    }

    /*/////////////////////////////////////////////////////////////
                    CORE NEXT TO THE SPOKE
    /////////////////////////////////////////////////////////////*/

    function test_coreViews_excludeSpokeSupply() public {
        vm.prank(admin);
        gateway.updateMintLimit(2_000e18);
        _coreDeposit(alice, 500e6);
        _mint(lp1, 1_000e6);
        assertEq(gateway.maxMint(), 1_500e18, "spoke supply does not use core room");
        assertEq(gateway.maxRedeem(lp1), 500e18, "the core backs only its own 500");
        assertEq(gateway.coreSupply(), 500e18);
    }

    /// @dev VUSD is fungible, so the core is not gated by wallet: spoke VUSD redeemed at the core takes core capacity
    /// (kept out by the legal agreement, bounded by the spoke's limit)
    function test_coreRedeem_spokeVusdTakesCoreCapacity() public {
        _coreDeposit(alice, 1_000e6);
        _mint(lp1, 1_000e6);

        vm.prank(lp1);
        assertEq(gateway.redeem(address(usdt), 400e18, 0, lp1), 400e6);
        assertEq(gateway.spokeSupply(address(spoke)), 1_000e18, "spoke supply is untouched");

        vm.startPrank(alice);
        assertEq(gateway.redeem(address(usdt), 600e18, 0, alice), 600e6);
        vm.expectRevert(abi.encodeWithSelector(Gateway.ExceededMaxWithdraw.selector, 400e6, 0));
        gateway.redeem(address(usdt), 400e18, 0, alice);
        vm.stopPrank();
    }

    /// @dev The core cap floors to the same token amount one wei above core supply, so the burn check is what stops it
    function test_coreRedeem_revertIfBurnDipsIntoSpokeSupply() public {
        _coreDeposit(alice, 1_000e6);
        _mint(lp1, 1_000e6);
        vm.prank(lp1);
        vusd.transfer(alice, 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Gateway.BurnBelowSpokeSupply.selector, 1_000e18 - 1, 1_000e18));
        gateway.redeem(address(usdt), 1_000e18 + 1, 0, alice);
    }

    /// @dev LPs earned more than the spoke holds (core yield): principal exits the spoke, the rest the core
    function test_drift_lpYieldBeyondSpokeSupplyExitsThroughCore() public {
        _coreDeposit(alice, 1_000e6);
        _mint(lp1, 1_000e6);
        _coreDeposit(address(this), 50e6);
        vusd.transfer(lp1, 50e18);

        assertEq(_redeem(lp1, 1_000e18), 1_000e6);
        assertEq(gateway.spokeSupply(address(spoke)), 0);
        vm.prank(lp1);
        assertEq(gateway.redeem(address(usdt), 50e18, 0, lp1), 50e6, "yield exits through the core");
    }

    /*/////////////////////////////////////////////////////////////
                            HARVEST
    /////////////////////////////////////////////////////////////*/

    function test_harvest_mintsSurplusAndRaisesSupply() public {
        _mint(lp1, 1_000e6);
        ct.setRate(1.1e18);

        assertEq(gateway.harvestable(address(spoke)), 100e18);
        vm.expectEmit(address(gateway));
        emit Gateway.Harvested(address(spoke), umm, 100e18);
        assertEq(_harvest(address(spoke)), 100e18);
        assertEq(vusd.balanceOf(umm), 100e18);
        assertEq(gateway.spokeSupply(address(spoke)), 1_100e18, "yield is backed in the spoke");
        assertEq(ct.balanceOf(address(spoke)), 1_000e6, "no collateral moves");
        assertEq(_harvest(address(spoke)), 0, "nothing left to harvest");
    }

    function test_harvest_upToAmount() public {
        _mint(lp1, 1_000e6);
        ct.setRate(1.1e18);

        vm.prank(umm);
        assertEq(gateway.harvest(address(spoke), umm, 40e18), 40e18);
        assertEq(gateway.spokeSupply(address(spoke)), 1_040e18);
        assertEq(gateway.harvestable(address(spoke)), 60e18);
        assertEq(_harvest(address(spoke)), 60e18, "the rest");
    }

    function test_harvest_nothingOnRateDrop() public {
        _mint(lp1, 1_000e6);
        ct.setRate(0.98e18);
        assertEq(gateway.harvestable(address(spoke)), 0);
        assertEq(_harvest(address(spoke)), 0);
    }

    function test_harvest_revertIfReceiverSanctioned() public {
        _mint(lp1, 1_000e6);
        ct.setRate(1.1e18);
        _sanction(stranger);
        vm.prank(umm);
        vm.expectRevert(abi.encodeWithSelector(Treasury.Sanctioned.selector, stranger));
        gateway.harvest(address(spoke), stranger, type(uint256).max);
    }

    /// @dev A removed spoke can still hold shares above its (zero) supply; harvesting them would mint supply the
    /// Gateway no longer counts
    function test_harvest_revertForRemovedSpokeWithShares() public {
        _mint(lp1, 1_000e6);
        ct.setRate(1.1e18);
        _redeem(lp1, 1_000e18);
        assertEq(gateway.spokeSupply(address(spoke)), 0);
        assertGt(ct.balanceOf(address(spoke)), 0, "surplus shares stay behind");
        vm.prank(admin);
        gateway.removeSpoke(address(spoke));

        vm.prank(umm);
        vm.expectRevert(abi.encodeWithSelector(Gateway.InvalidSpoke.selector, address(spoke)));
        gateway.harvest(address(spoke), umm, type(uint256).max);
    }

    function test_harvest_revertIfNotUmmZeroReceiverOrNotASpoke() public {
        bytes32 _role = gateway.UMM_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Gateway.AccessControlUnauthorizedAccount.selector, stranger, _role));
        gateway.harvest(address(0), stranger, type(uint256).max);
        vm.prank(umm);
        vm.expectRevert(Gateway.AddressIsZero.selector);
        gateway.harvest(address(0), address(0), type(uint256).max);
        vm.prank(umm);
        vm.expectRevert(abi.encodeWithSelector(Gateway.InvalidSpoke.selector, stranger));
        gateway.harvest(stranger, umm, type(uint256).max);
    }

    /// @dev Each source is harvested on its own and in either order: a spoke's yield raises its supply and the total
    /// supply together, so the core's excess is unchanged
    function test_harvest_coreAndSpokeSeparately() public {
        _coreDeposit(alice, 1_000e6);
        _mint(lp1, 1_000e6);
        deal(address(usdt), address(treasury), usdt.balanceOf(address(treasury)) + 10e6);
        uint256 _reserve = treasury.reserve();
        ct.setRate(1.1e18);

        assertEq(_harvest(address(spoke)), 100e18);
        assertEq(gateway.harvestable(address(0)), 10e18, "core excess unchanged by the spoke harvest");
        vm.expectEmit(address(gateway));
        emit Gateway.Harvested(address(0), umm, 10e18);
        assertEq(_harvest(address(0)), 10e18);
        assertEq(gateway.spokeSupply(address(spoke)), 1_100e18);
        assertEq(treasury.reserve(), _reserve, "no core collateral moves");
        assertEq(treasury.reserve(), gateway.coreSupply(), "core exactly backed");
    }

    /// @dev The caller picks the source, so one that cannot be valued reverts; the others stay harvestable
    function test_harvest_revertForUnreadableSource() public {
        _coreDeposit(alice, 1_000e6);
        _mint(lp1, 1_000e6);
        deal(address(usdt), address(treasury), usdt.balanceOf(address(treasury)) + 10e6);
        ct.setRate(1.1e18);

        vm.mockCallRevert(address(ct), abi.encodeWithSelector(MockRateVault.convertToAssets.selector), "paused");
        vm.prank(umm);
        vm.expectRevert("paused");
        gateway.harvest(address(spoke), umm, type(uint256).max);
        assertEq(_harvest(address(0)), 10e18, "core still harvested");
        vm.clearMockedCalls();

        vm.warp(block.timestamp + 2 days); // core feed stale, reserve() reverts
        vm.prank(umm);
        vm.expectRevert(abi.encodeWithSelector(Treasury.StalePrice.selector, address(usdtOracle)));
        gateway.harvest(address(0), umm, type(uint256).max);
        assertEq(_harvest(address(spoke)), 100e18, "spoke still harvested");
    }

    function test_harvest_notBoundByMintLimit() public {
        _mint(lp1, 1_000e6);
        vm.prank(admin);
        gateway.decreaseSpokeMintLimit(address(spoke), 1_000e18);
        ct.setRate(1.1e18);
        assertEq(_harvest(address(spoke)), 100e18);
        assertEq(spoke.maxMint(), 0, "harvested yield fills the limit");
    }

    /// @dev No buffer is kept: a small negative report after a harvest shuts mints until the rate recovers (accepted)
    function test_harvest_thenSmallDropShutsMintsUntilRecovery() public {
        _mint(lp1, 1_000_000e6);
        ct.setRate(1.0001e18);
        assertEq(_harvest(address(spoke)), 100e18);

        ct.setRate(1e18);
        assertEq(spoke.maxMint(), 0);
        _fundAndApprove(lp2, 1e6);
        vm.expectRevert(abi.encodeWithSelector(Gateway.SpokeUndercollateralized.selector, 1_000_001e18, 1_000_101e18));
        spoke.mint(1e6, 0, lp2);
        vm.stopPrank();

        ct.setRate(1.0001e18);
        assertGt(spoke.maxMint(), 0, "mints reopen once the spoke is whole");
    }

    function test_yieldManager_harvestBatchSumsEverySource() public {
        MockRateVault _ct2 = new MockRateVault(address(usdt));
        ConcreteSpoke _spoke2 = _deploySpoke(_ct2);
        _addSpoke(_spoke2);
        _whitelist(_spoke2, lp1);

        _coreDeposit(alice, 1_000e6);
        _mint(lp1, 1_000e6);
        _ct2.mint(lp1, 1_000e6);
        vm.startPrank(lp1);
        _ct2.approve(address(_spoke2), 1_000e6);
        _spoke2.mint(1_000e6, 0, lp1);
        vm.stopPrank();
        deal(address(usdt), address(treasury), usdt.balanceOf(address(treasury)) + 10e6);
        ct.setRate(1.1e18);
        _ct2.setRate(1.2e18);

        address[] memory _sources = new address[](3);
        _sources[1] = address(spoke);
        _sources[2] = address(_spoke2);
        uint256[] memory _amounts = new uint256[](3);
        _amounts[0] = _amounts[1] = _amounts[2] = type(uint256).max;
        vm.prank(keeper);
        assertEq(yieldManager.harvestBatch(_sources, _amounts), 310e18);
        assertEq(yieldManager.buffer(), 310e18);
        assertEq(gateway.spokeSupply(address(spoke)), 1_100e18);
        assertEq(gateway.spokeSupply(address(_spoke2)), 1_200e18);
        assertEq(gateway.totalSpokeSupply(), 2_300e18);
        assertEq(treasury.reserve(), gateway.coreSupply(), "core exactly backed");
    }

    /// @dev A source that cannot be valued reverts the batch; leaving it out harvests the others
    function test_yieldManager_harvestBatchWithoutUnreadableSource() public {
        _coreDeposit(alice, 1_000e6);
        _mint(lp1, 1_000e6);
        ct.setRate(1.1e18);
        vm.warp(block.timestamp + 2 days); // core feed stale
        address[] memory _both = new address[](2);
        _both[1] = address(spoke);
        uint256[] memory _all = new uint256[](2);
        _all[0] = _all[1] = type(uint256).max;

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Treasury.StalePrice.selector, address(usdtOracle)));
        yieldManager.harvestBatch(_both, _all);

        address[] memory _spokeOnly = new address[](1);
        _spokeOnly[0] = address(spoke);
        uint256[] memory _one = new uint256[](1);
        _one[0] = type(uint256).max;
        vm.prank(keeper);
        assertEq(yieldManager.harvestBatch(_spokeOnly, _one), 100e18, "spoke harvested");
    }

    /// @dev The core's yield only counts the supply it backs, so spoke supply does not hide it
    function test_yieldManager_harvestCoreExcludesSpokeSupply() public {
        _coreDeposit(alice, 1_000e6);
        _mint(lp1, 1_000e6);
        deal(address(usdt), address(treasury), usdt.balanceOf(address(treasury)) + 10e6); // core yield

        assertEq(yieldManager.harvestable(address(0)), 10e18);
        vm.prank(keeper);
        assertEq(yieldManager.harvest(address(0), type(uint256).max), 10e18);
        assertEq(yieldManager.buffer(), 10e18);
    }

    /*/////////////////////////////////////////////////////////////
                        LOSS: 1:1, FIRST COME
    /////////////////////////////////////////////////////////////*/

    function test_loss_firstComeAtPar() public {
        _coreDeposit(alice, 1_000e6);
        _mint(lp1, 1_000e6);
        _mint(lp2, 1_000e6);
        ct.setRate(0.9e18);
        assertEq(spoke.maxMint(), 0, "mints stop while undercollateralized");

        assertEq(_redeem(lp1, 1_000e18), 1_111_111_111, "first redeemer paid in full at 1:1");
        uint256 _max = spoke.maxRedeem(lp2);
        assertEq(_max, 800.0000001e18, "what the remaining 888.888889 shares are worth");
        vm.prank(lp2);
        vm.expectRevert();
        spoke.redeem(1_000e18, 0, lp2);
        assertEq(_redeem(lp2, _max), 888_888_889, "the last shares");
        assertEq(gateway.spokeSupply(address(spoke)), 200e18 - 0.0000001e18, "nothing behind the rest");

        // Core holders are untouched while the shortfall stays out of the core (legal agreement, not code)
        vm.prank(alice);
        assertEq(gateway.redeem(address(usdt), 1_000e18, 0, alice), 1_000e6);
    }

    function test_loss_undercollateralizedSpokeRefusesMintsUntilMadeWhole() public {
        _mint(lp1, 1_000e6);
        ct.setRate(0.9e18); // spoke worth 900 against 1,000 supply

        _fundAndApprove(lp2, 100e6);
        vm.expectRevert(abi.encodeWithSelector(Gateway.SpokeUndercollateralized.selector, 990e18, 1_090e18));
        spoke.mint(100e6, 0, lp2);
        vm.stopPrank();

        // Concrete makes the spoke whole: mints reopen at the current rate
        ct.mint(address(spoke), 111_111_112);
        assertEq(_mint(lp2, 100e6), 90e18);
    }

    /*/////////////////////////////////////////////////////////////
                            VIEWS
    /////////////////////////////////////////////////////////////*/

    function test_maxMint_roomAndBlocks() public {
        ct.setRate(1.05e18);
        vm.prank(admin);
        gateway.decreaseSpokeMintLimit(address(spoke), 1_050e18);
        assertEq(spoke.maxMint(), 1_050e18);

        assertEq(_mint(lp1, 500e6), 525e18);
        assertEq(spoke.maxMint(), 525e18);
        ct.setRate(1.04e18);
        assertEq(spoke.maxMint(), 0, "undercollateralized");
    }

    function test_maxRedeem_cappedByBalanceSupplyAndWhitelist() public {
        _mint(lp1, 1_000e6);
        assertEq(spoke.maxRedeem(lp1), 1_000e18);
        assertEq(spoke.maxRedeem(stranger), 0, "not whitelisted");

        _coreDeposit(alice, 500e6);
        vm.prank(alice);
        vusd.transfer(lp1, 500e18);
        assertEq(spoke.maxRedeem(lp1), 1_000e18, "capped by spoke supply");
        assertEq(_redeem(lp1, spoke.maxRedeem(lp1)), 1_000e6);
    }

    function test_maxRedeem_zeroForSanctioned() public {
        _mint(lp1, 100e6);
        _sanction(lp1);
        assertEq(spoke.maxRedeem(lp1), 0, "sanctioned");
        _sanction(lp2);
        assertEq(spoke.maxRedeem(lp1), 100e18);
    }

    /// @dev Less than one share unit's worth would revert, so the view offers nothing
    function test_maxRedeem_zeroForDust() public {
        _mint(lp1, 100e6);
        vm.prank(lp1);
        vusd.transfer(lp2, 100e18 - 1e11);
        assertEq(spoke.maxRedeem(lp1), 0, "1e11 wei is a tenth of a share unit");
        assertEq(spoke.maxRedeem(lp2), 100e18 - 1e11);
    }

    /// @dev The room converted to shares always fits: no rounding pushes a max mint past the limit or the collateral
    /// check
    function testFuzz_mintAtMaxMintFits(uint256 priorShares_, uint256 extraRoom_, uint256 rate_) public {
        priorShares_ = bound(priorShares_, 0, 1_000_000e6);
        rate_ = bound(rate_, 0.9e18, 1.3e18);
        if (priorShares_ > 0) _mint(lp1, priorShares_);
        ct.setRate(rate_);
        uint256 _limit = gateway.spokeSupply(address(spoke)) + bound(extraRoom_, 1, 5_000_000e18);
        vm.prank(admin);
        gateway.decreaseSpokeMintLimit(address(spoke), _limit);

        uint256 _room = spoke.maxMint();
        if (_room == 0) return;
        // Shares for the room, rounded down so the mint fits
        uint256 _shares = spoke.previewRedeem(_room);
        if (_shares == 0) return;
        _mint(lp2, _shares);
        assertLe(gateway.spokeSupply(address(spoke)), _limit);
        assertGe(spoke.reserve(), gateway.spokeSupply(address(spoke)));
    }

    /// @dev Concrete paused or stale: the spoke's mints and exits stop (acknowledged), the core and its harvest do not
    function test_sharePriceReverting_spokeStopsCoreLive() public {
        _coreDeposit(alice, 1_000e6);
        _mint(lp1, 1_000e6);
        vm.mockCallRevert(address(ct), abi.encodeWithSelector(MockRateVault.convertToAssets.selector), "");

        assertEq(spoke.maxMint(), 0);
        assertEq(spoke.maxRedeem(lp1), 0, "exit view agrees with the reverting redeem");
        vm.prank(lp1);
        vm.expectRevert();
        spoke.redeem(100e18, 0, lp1);

        assertEq(_coreDeposit(alice, 100e6), 100e18);
        vm.prank(alice);
        assertEq(gateway.redeem(address(usdt), 100e18, 0, alice), 100e6);
        deal(address(usdt), address(treasury), usdt.balanceOf(address(treasury)) + 10e6);
        assertEq(yieldManager.harvestable(address(0)), 10e18);
    }

    /// @dev The spoke and the Gateway read the PeggedToken's Treasury live: after a swap, sanctions come from the new
    /// one, and mints and exits are unaffected
    function test_treasurySwap_spokeUsesNewTreasury() public {
        _mint(lp1, 100e6);
        Treasury _new = deployTreasury(address(vusd), admin);
        MockChainlinkOracle _oracle = new MockChainlinkOracle(0.995e8);
        vm.prank(admin);
        _new.addToWhitelist(address(usdt), address(coreVault), address(_oracle), 1 days);
        vusd.updateTreasury(address(_new));

        assertEq(_mint(lp2, 100e6), 100e18, "1:1 whatever the new Treasury's USDT price");
        assertEq(_redeem(lp1, 100e18), 100e6, "exit unaffected");

        MockSanctionsList _sanctions = new MockSanctionsList();
        vm.prank(admin);
        _new.updateSanctionsList(address(_sanctions));
        _sanctions.setSanctioned(lp2, true);
        assertEq(spoke.maxRedeem(lp2), 0, "new Treasury's sanctions list");
    }

    /*/////////////////////////////////////////////////////////////
                            INITIALIZE
    /////////////////////////////////////////////////////////////*/

    function test_initialize_revertForZeroOrWrongDecimals() public {
        address _impl = address(new ConcreteSpoke());
        vm.expectRevert(ConcreteSpoke.AddressIsZero.selector);
        new ERC1967Proxy(
            _impl, abi.encodeCall(ConcreteSpoke.initialize, (address(0), address(vusd), address(ct), address(svusd)))
        );

        usdt.setDecimals(19);
        vm.expectRevert(abi.encodeWithSelector(ConcreteSpoke.InvalidTokenDecimals.selector, address(usdt), 19));
        new ERC1967Proxy(
            _impl,
            abi.encodeCall(ConcreteSpoke.initialize, (address(manager), address(vusd), address(ct), address(svusd)))
        );
    }

    function test_initialize_onlyOnce() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        spoke.initialize(address(manager), address(vusd), address(ct), address(svusd));
    }
}
