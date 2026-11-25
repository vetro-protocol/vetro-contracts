// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ConcreteSpoke} from "src/ConcreteSpoke.sol";
import {Gateway} from "src/Gateway.sol";
import {PeggedToken} from "src/PeggedToken.sol";
import {StakingVault} from "src/StakingVault.sol";
import {Treasury} from "src/Treasury.sol";
import {MockChainlinkOracle} from "test/mocks/MockChainlinkOracle.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockRateVault} from "test/mocks/MockRateVault.sol";
import {ConcreteSpokeBase} from "test/ConcreteSpoke.t.sol";

uint256 constant SPOKE_COUNT = 2;

struct HandlerEnv {
    Gateway gateway;
    PeggedToken vusd;
    Treasury treasury;
    StakingVault svusd;
    ConcreteSpoke[SPOKE_COUNT] spokes;
    MockRateVault[SPOKE_COUNT] cts;
    MockERC20 usdt;
    MockChainlinkOracle usdtOracle;
    address umm;
    address vetro;
    address concrete;
    address admin;
}

/// @notice Random spoke and core flows side by side over two spokes: LP mints to VUSD and to sVUSD, redeems from VUSD
/// and from sVUSD, force exits from both, mint stops (limit 0) and shutdowns, core mints and redeems (including spoke
/// VUSD sent to the core), AMO mints and burns, transfers, share rate steps and jumps, a spoke's share rate
/// reverting (Concrete paused), core yield, share donations, the USDT feed moving off par or going stale, time passing.
/// One actor is not whitelisted on the spokes.
/// @dev Reverts are swallowed so sequences keep going, so the properties that matter are tracked as ghosts instead:
/// a call that should succeed (within the max views) and reverted, a call that should revert and went through.
contract ConcreteSpokeHandler is Test {
    Gateway internal gateway;
    PeggedToken internal vusd;
    Treasury internal treasury;
    StakingVault internal svusd;
    ConcreteSpoke[SPOKE_COUNT] internal spokes;
    MockRateVault[SPOKE_COUNT] internal cts;
    MockERC20 internal usdt;
    MockChainlinkOracle internal usdtOracle;
    address internal umm;
    address internal vetro;
    address internal concrete;
    address internal admin;
    address[] internal lps;
    address[] internal holders;

    uint256[SPOKE_COUNT] public ghost_spokeMinted;
    uint256[SPOKE_COUNT] public ghost_spokeBurned;
    // A spoke mint that left the spoke worth less than its supply, valued from the share balance and rate rather than
    // the spoke's own reserve
    uint256 public ghost_undercollateralizedMints;
    // A spoke mint that minted other than the shares' value at the share price, computed here
    uint256 public ghost_mintMismatches;
    // A mint within the spoke's max view, or a redeem the spoke can pay, that reverted
    uint256 public ghost_livenessFailures;
    // A spoke call that went through for a non-whitelisted account or during a shutdown
    uint256 public ghost_unexpectedSuccesses;
    uint256 public ghost_rateReverts;

    bool[SPOKE_COUNT] internal paused;

    constructor(HandlerEnv memory env_, address[] memory lps_, address[] memory holders_) {
        gateway = env_.gateway;
        vusd = env_.vusd;
        treasury = env_.treasury;
        svusd = env_.svusd;
        spokes = env_.spokes;
        cts = env_.cts;
        usdt = env_.usdt;
        usdtOracle = env_.usdtOracle;
        umm = env_.umm;
        vetro = env_.vetro;
        concrete = env_.concrete;
        admin = env_.admin;
        lps = lps_;
        holders = holders_;
    }

    /*/////////////////////////////////////////////////////////////
                            SPOKE FLOWS
    /////////////////////////////////////////////////////////////*/

    /// @dev Within `maxMint` the mint must go through; above it (or when it is 0) it may revert
    function spokeMint(uint256 spokeSeed_, uint256 actorSeed_, uint256 shares_, bool stake_) external {
        uint256 _i = spokeSeed_ % SPOKE_COUNT;
        address _lp = lps[actorSeed_ % lps.length];
        ConcreteSpoke _spoke = spokes[_i];
        bool _withinMax;
        (shares_, _withinMax) = _boundMint(_spoke, shares_);
        cts[_i].mint(_lp, shares_);
        vm.startPrank(_lp);
        cts[_i].approve(address(_spoke), shares_);
        uint256 _totalBefore = vusd.totalSupply();
        uint256 _expected = _expectedMint(_i, shares_);
        bool _mustRevert = !_spoke.isWhitelisted(_lp) || _spoke.shutdown();
        bool _ok;
        if (stake_) {
            try _spoke.mintAndStake(shares_, 0, _lp) {
                _ok = true;
            } catch {}
        } else {
            try _spoke.mint(shares_, 0, _lp) {
                _ok = true;
            } catch {}
        }
        vm.stopPrank();
        if (_ok) {
            // The VUSD actually minted, measured apart from the ledger it is checked against
            uint256 _minted = vusd.totalSupply() - _totalBefore;
            ghost_spokeMinted[_i] += _minted;
            if (_minted != _expected) ghost_mintMismatches++;
            if (_spokeValue(_i) < gateway.spokeSupply(address(_spoke))) ghost_undercollateralizedMints++;
            if (_mustRevert) ghost_unexpectedSuccesses++;
        } else if (_withinMax && !_mustRevert) {
            ghost_livenessFailures++;
        }
    }

    function spokeRedeem(uint256 spokeSeed_, uint256 actorSeed_, uint256 amount_) external {
        uint256 _i = spokeSeed_ % SPOKE_COUNT;
        address _lp = lps[actorSeed_ % lps.length];
        uint256 _max = Math.min(vusd.balanceOf(_lp), gateway.spokeSupply(address(spokes[_i])));
        if (_max == 0) return;
        amount_ = bound(amount_, 1, _max);
        bool _mustRevert = !spokes[_i].isWhitelisted(_lp) || spokes[_i].shutdown();
        bool _payable = !_mustRevert && _spokePays(_i, amount_);
        vm.prank(_lp);
        try spokes[_i].redeem(amount_, 0, _lp) {
            ghost_spokeBurned[_i] += amount_;
            if (_mustRevert) ghost_unexpectedSuccesses++;
        } catch {
            if (_payable) ghost_livenessFailures++;
        }
    }

    function unstakeAndRedeem(uint256 spokeSeed_, uint256 actorSeed_, uint256 shares_) external {
        uint256 _i = spokeSeed_ % SPOKE_COUNT;
        address _lp = lps[actorSeed_ % lps.length];
        uint256 _balance = svusd.balanceOf(_lp);
        if (_balance == 0) return;
        shares_ = bound(shares_, 1, _balance);
        uint256 _peggedTokenIn = svusd.previewRedeem(shares_);
        bool _mustRevert = !spokes[_i].isWhitelisted(_lp) || spokes[_i].shutdown();
        bool _payable = !_mustRevert && _peggedTokenIn > 0 && _peggedTokenIn <= gateway.spokeSupply(address(spokes[_i]))
            && _spokePays(_i, _peggedTokenIn);
        uint256 _totalBefore = vusd.totalSupply();
        vm.startPrank(_lp);
        svusd.approve(address(spokes[_i]), shares_);
        try spokes[_i].unstakeAndRedeem(shares_, 0, _lp) {
            // The VUSD actually burned, not the preview
            ghost_spokeBurned[_i] += _totalBefore - vusd.totalSupply();
            if (_mustRevert) ghost_unexpectedSuccesses++;
        } catch {
            if (_payable) ghost_livenessFailures++;
        }
        vm.stopPrank();
    }

    function forceRedeem(uint256 spokeSeed_, uint256 actorSeed_, uint256 amount_) external {
        uint256 _i = spokeSeed_ % SPOKE_COUNT;
        address _lp = lps[actorSeed_ % lps.length];
        uint256 _max = Math.min(vusd.balanceOf(_lp), gateway.spokeSupply(address(spokes[_i])));
        if (_max == 0) return;
        amount_ = bound(amount_, 1, _max);
        bool _mustRevert = !spokes[_i].isWhitelisted(_lp) || spokes[_i].shutdown();
        bool _payable = !_mustRevert && _spokePays(_i, amount_);
        vm.prank(concrete);
        try spokes[_i].forceRedeem(_lp, amount_, 0) {
            ghost_spokeBurned[_i] += amount_;
            if (_mustRevert) ghost_unexpectedSuccesses++;
        } catch {
            if (_payable) ghost_livenessFailures++;
        }
    }

    function forceUnstakeAndRedeem(uint256 spokeSeed_, uint256 actorSeed_, uint256 shares_) external {
        uint256 _i = spokeSeed_ % SPOKE_COUNT;
        address _lp = lps[actorSeed_ % lps.length];
        uint256 _balance = svusd.balanceOf(_lp);
        if (_balance == 0) return;
        shares_ = bound(shares_, 1, _balance);
        uint256 _peggedTokenIn = svusd.previewRedeem(shares_);
        bool _mustRevert = !spokes[_i].isWhitelisted(_lp) || spokes[_i].shutdown();
        bool _payable = !_mustRevert && _peggedTokenIn > 0 && _peggedTokenIn <= gateway.spokeSupply(address(spokes[_i]))
            && _spokePays(_i, _peggedTokenIn);
        // The LP keeps an sVUSD allowance to the spoke under its agreement
        vm.prank(_lp);
        svusd.approve(address(spokes[_i]), shares_);
        uint256 _totalBefore = vusd.totalSupply();
        vm.prank(concrete);
        try spokes[_i].forceUnstakeAndRedeem(_lp, shares_, 0) {
            ghost_spokeBurned[_i] += _totalBefore - vusd.totalSupply();
            if (_mustRevert) ghost_unexpectedSuccesses++;
        } catch {
            if (_payable) ghost_livenessFailures++;
        }
    }

    /// @dev Vetro stops a spoke's mints by lowering its Gateway limit to 0, and reopens them
    function stopMints(uint256 spokeSeed_, bool stop_) external {
        address _spoke = address(spokes[spokeSeed_ % SPOKE_COUNT]);
        uint256 _limit = gateway.spokeMintLimit(_spoke);
        vm.startPrank(admin);
        if (stop_ && _limit > 0) gateway.decreaseSpokeMintLimit(_spoke, 0);
        else if (!stop_ && _limit < 2_000_000e18) gateway.increaseSpokeMintLimit(_spoke, 2_000_000e18);
        vm.stopPrank();
    }

    /// @dev Rarely on, so most sequences keep their exits
    function setShutdown(uint256 spokeSeed_, uint256 seed_) external {
        vm.prank(concrete);
        spokes[spokeSeed_ % SPOKE_COUNT].setShutdown(seed_ % 4 == 0);
    }

    /*/////////////////////////////////////////////////////////////
                            CORE AND AMO
    /////////////////////////////////////////////////////////////*/

    function coreDeposit(uint256 actorSeed_, uint256 amount_) external {
        address _holder = holders[actorSeed_ % holders.length];
        amount_ = bound(amount_, 1e6, 1_000_000e6);
        deal(address(usdt), _holder, amount_);
        vm.startPrank(_holder);
        usdt.approve(address(gateway), amount_);
        try gateway.deposit(address(usdt), amount_, 0, _holder) {} catch {}
        vm.stopPrank();
    }

    /// @dev Any VUSD, spoke-minted or AMO included, can be redeemed at the core
    function coreRedeem(uint256 actorSeed_, uint256 amount_) external {
        address _holder = holders[actorSeed_ % holders.length];
        uint256 _balance = vusd.balanceOf(_holder);
        if (_balance == 0) return;
        amount_ = bound(amount_, 1, _balance);
        vm.prank(_holder);
        try gateway.redeem(address(usdt), amount_, 0, _holder) {} catch {}
    }

    function amoMint(uint256 amount_) external {
        uint256 _max = gateway.maxAmoMint();
        if (_max == 0) return;
        vm.prank(umm);
        gateway.mintToAMO(bound(amount_, 1, _max), umm);
    }

    function amoBurn(uint256 amount_) external {
        uint256 _max = Math.min(vusd.balanceOf(umm), gateway.amoSupply());
        if (_max == 0) return;
        vm.prank(umm);
        gateway.burnFromAMO(bound(amount_, 1, _max));
    }

    function transfer(uint256 fromSeed_, uint256 toSeed_, uint256 amount_) external {
        address _from = holders[fromSeed_ % holders.length];
        address _to = holders[toSeed_ % holders.length];
        uint256 _balance = vusd.balanceOf(_from);
        if (_balance == 0 || _from == _to) return;
        amount_ = bound(amount_, 1, _balance);
        vm.prank(_from);
        vusd.transfer(_to, amount_);
    }

    /*/////////////////////////////////////////////////////////////
                        MARKET AND TIME
    /////////////////////////////////////////////////////////////*/

    /// @dev A jump anywhere between 0.9 and 1.3
    function setRate(uint256 spokeSeed_, uint256 rate_) external {
        cts[spokeSeed_ % SPOKE_COUNT].setRate(bound(rate_, 0.9e18, 1.3e18));
    }

    /// @dev A report-sized step: up to 50 bps either way, as Concrete reports move without pausing
    function stepRate(uint256 spokeSeed_, uint256 bps_, bool up_) external {
        MockRateVault _ct = cts[spokeSeed_ % SPOKE_COUNT];
        uint256 _rate = _ct.rateWad();
        uint256 _step = _rate * bound(bps_, 0, 50) / 10_000;
        _ct.setRate(up_ ? _rate + _step : _rate - _step);
    }

    /// @dev Concrete paused or stale: the share rate reverts until unpaused
    function pauseRate(uint256 spokeSeed_) external {
        uint256 _i = spokeSeed_ % SPOKE_COUNT;
        vm.mockCallRevert(address(cts[_i]), abi.encodeWithSelector(MockRateVault.convertToAssets.selector), "paused");
        paused[_i] = true;
        ghost_rateReverts++;
    }

    function unpauseRates() external {
        vm.clearMockedCalls();
        for (uint256 i; i < SPOKE_COUNT; ++i) {
            paused[i] = false;
        }
    }

    function coreYield(uint256 amount_) external {
        amount_ = bound(amount_, 1, 10_000e6);
        deal(address(usdt), address(treasury), usdt.balanceOf(address(treasury)) + amount_);
    }

    function donateShares(uint256 spokeSeed_, uint256 shares_) external {
        uint256 _i = spokeSeed_ % SPOKE_COUNT;
        cts[_i].mint(address(spokes[_i]), bound(shares_, 1, 10_000e6));
    }

    /// @dev The USDT feed, fresh, between 0.98 and 1.02: core mints pause beyond the Treasury's 1% tolerance and price
    /// at the oracle below par; spoke mints stay 1:1 throughout
    function setUnderlyingPrice(uint256 price_) external {
        usdtOracle.updatePrice(int256(bound(price_, 0.98e8, 1.02e8)));
    }

    /// @dev Without a refresh the feed goes stale: core pricing reverts, spoke mints carry on
    function passTime(uint256 seconds_, bool refresh_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 7 days));
        if (refresh_) usdtOracle.updatePrice(1e8);
    }

    /*/////////////////////////////////////////////////////////////
                                HELPERS
    /////////////////////////////////////////////////////////////*/

    /// @dev Shares to mint: within the max (the room converted down to shares), exactly at it a third of those times,
    /// since that is where rounding would push past the limit; else anything
    function _boundMint(ConcreteSpoke spoke_, uint256 shares_)
        internal
        view
        returns (uint256 _shares, bool _withinMax)
    {
        uint256 _room = spoke_.maxMint();
        uint256 _maxShares = _room == 0 ? 0 : spoke_.previewRedeem(_room);
        _withinMax = _maxShares > 0 && shares_ % 4 != 0;
        if (!_withinMax) return (bound(shares_, 1e6, 1_000_000e6), false);
        if (shares_ % 3 == 0) return (_maxShares, true);
        _shares = bound(shares_, 1, Math.min(_maxShares, 1_000_000e6));
        // Dust that mints nothing reverts, and is not a liveness failure
        if (spoke_.previewMint(_shares) == 0) _withinMax = false;
    }

    /// @dev The spoke's shares at the rate, USDT at par, computed from the share balance and the rate as the spoke
    /// prices them (whole-share rate truncated to the share's 6 decimals)
    function _spokeValue(uint256 i_) internal view returns (uint256) {
        uint256 _sharePrice = (1e6 * cts[i_].rateWad() / 1e18) * 1e12;
        return cts[i_].balanceOf(address(spokes[i_])) * _sharePrice / 1e6;
    }

    /// @dev VUSD for `shares_` at the rate, USDT at par whatever its price (1:1)
    function _expectedMint(uint256 i_, uint256 shares_) internal view returns (uint256) {
        uint256 _sharePrice = (1e6 * cts[i_].rateWad() / 1e18) * 1e12;
        return shares_ * _sharePrice / 1e6;
    }

    /// @dev Whether a spoke redeem of `amount_` must succeed: open, the rate reads, it pays at least one share unit
    /// (dust reverts) and the spoke holds the shares
    function _spokePays(uint256 i_, uint256 amount_) internal view returns (bool) {
        if (paused[i_] || spokes[i_].shutdown()) return false;
        try spokes[i_].previewRedeem(amount_) returns (uint256 _out) {
            return _out > 0 && _out <= cts[i_].balanceOf(address(spokes[i_]));
        } catch {
            return false;
        }
    }
}

contract ConcreteSpokeInvariantTest is ConcreteSpokeBase {
    // VUSD each spoke mints in setUp, before the handler counts
    uint256 internal constant SEEDED = 100_000e18;

    ConcreteSpokeHandler internal handler;
    ConcreteSpoke internal spoke2;
    MockRateVault internal ct2;

    function setUp() public override {
        super.setUp();

        // A second spoke, so the ledger is exercised across spokes
        ct2 = new MockRateVault(address(usdt));
        spoke2 = _deploySpoke(ct2);
        _addSpoke(spoke2);
        _whitelist(spoke2, lp1);
        _whitelist(spoke2, lp2);
        // Limits the handler can fill, so mints run into them and mints at exactly the max get exercised
        vm.startPrank(admin);
        gateway.decreaseSpokeMintLimit(address(spoke), 2_000_000e18);
        gateway.decreaseSpokeMintLimit(address(spoke2), 2_000_000e18);
        gateway.updateAmoMintLimit(1_000_000e18);
        // The live 3 bps band for the core, which prices USDT while the spoke does not
        treasury.updatePegBand(address(usdt), 3);
        vm.stopPrank();

        // Staked positions from the start, so the staked exit runs from the first call
        _seedStake(spoke, ct, lp1);
        _seedStake(spoke2, ct2, lp2);

        // The stranger is not whitelisted on either spoke: its calls must all revert
        address[] memory _lps = new address[](3);
        _lps[0] = lp1;
        _lps[1] = lp2;
        _lps[2] = stranger;
        address[] memory _holders = new address[](5);
        _holders[0] = alice;
        _holders[1] = lp1;
        _holders[2] = lp2;
        _holders[3] = umm;
        _holders[4] = stranger;
        HandlerEnv memory _env = HandlerEnv({
            gateway: gateway,
            vusd: vusd,
            treasury: treasury,
            svusd: svusd,
            spokes: [spoke, spoke2],
            cts: [ct, ct2],
            usdt: usdt,
            usdtOracle: usdtOracle,
            umm: umm,
            vetro: vetro,
            concrete: concrete,
            admin: admin
        });
        handler = new ConcreteSpokeHandler(_env, _lps, _holders);
        // The handler's core holders redeem instantly, like the unit tests' actors
        gateway.addToInstantRedeemWhitelist(umm);
        gateway.addToInstantRedeemWhitelist(stranger);
        targetContract(address(handler));
    }

    function _seedStake(ConcreteSpoke spoke_, MockRateVault ct_, address lp_) internal {
        ct_.mint(lp_, 100_000e6);
        vm.startPrank(lp_);
        ct_.approve(address(spoke_), 100_000e6);
        spoke_.mintAndStake(100_000e6, 0, lp_);
        vm.stopPrank();
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 128
    function invariant_supplyBucketsAddUp() public view {
        assertEq(
            vusd.totalSupply(),
            gateway.coreSupply() + gateway.totalSpokeSupply(),
            "core and spoke supply (the AMO's included) add up to the total"
        );
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 128
    function invariant_spokeLedger() public view {
        ConcreteSpoke[SPOKE_COUNT] memory _spokes = [spoke, spoke2];
        uint256 _total;
        for (uint256 i; i < SPOKE_COUNT; ++i) {
            uint256 _supply = gateway.spokeSupply(address(_spokes[i]));
            _total += _supply;
            assertEq(
                _supply, SEEDED + handler.ghost_spokeMinted(i) - handler.ghost_spokeBurned(i), "minted less burned"
            );
        }
        assertEq(gateway.totalSpokeSupply(), gateway.amoSupply() + _total, "total is the AMO plus every spoke");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 128
    function invariant_noMintIntoUndercollateralizedSpoke() public view {
        assertEq(handler.ghost_undercollateralizedMints(), 0);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 128
    function invariant_mintsAtSharePrice() public view {
        assertEq(handler.ghost_mintMismatches(), 0);
    }

    /// @dev The core stays fully backed with its USDT counted at par: spoke and AMO VUSD redeemed at the core take USDT
    /// and supply out together, and below par core mints price USDT at the oracle while redeems pay par
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 128
    function invariant_coreBacked() public view {
        uint256 _coreSupply = gateway.coreSupply();
        uint256 _usdt =
            usdt.balanceOf(address(treasury)) + coreVault.convertToAssets(coreVault.balanceOf(address(treasury)));
        assertGe(_usdt * 1e12, _coreSupply);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 128
    function invariant_spokeCallsRevertWhenTheyMust() public view {
        assertEq(handler.ghost_unexpectedSuccesses(), 0);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 128
    function invariant_maxViewsHonoured() public view {
        assertEq(handler.ghost_livenessFailures(), 0);
    }
}
