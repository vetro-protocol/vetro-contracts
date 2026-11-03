// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AggregatorV2V3Interface} from "@chainlink/contracts/interfaces/feeds/AggregatorV2V3Interface.sol";
import {CurveStableSwapNGEmaFeedAdapter} from "src/CurveStableSwapNGEmaFeedAdapter.sol";
import {DerivedPriceFeedAdapter} from "src/DerivedPriceFeedAdapter.sol";
import {MinPriceFeedAdapter} from "src/MinPriceFeedAdapter.sol";
import {ICurveStableSwapNG} from "src/interfaces/curve/ICurveStableSwapNG.sol";
import {PeggedToken} from "src/PeggedToken.sol";
import {Gateway} from "src/Gateway.sol";
import {Treasury} from "src/Treasury.sol";
import {deployTreasury} from "test/helpers/Deploy.sol";
import {cbBTC} from "test/helpers/Address.ethereum.sol";

interface ICurveExchange {
    function exchange(int128 i, int128 j, uint256 dx, uint256 minDy) external returns (uint256);
}

contract PassthroughVault is ERC4626 {
    constructor(IERC20 asset_) ERC20("Passthrough", "PT") ERC4626(asset_) {}
}

/// @dev The feeds as the deploy scripts build them, priced in WBTC, on a Treasury and Gateway from this repo:
///      WBTC at a fixed 1.0, cbBTC = min(cbBTC/BTC derived / WBTC/BTC, Curve EMA cbBTC/WBTC),
///      hemiBTC = min(HEMIBTC/BTC exchange rate / WBTC/BTC, Curve EMA hemiBTC/WBTC), all with a 90000 s stale period
///      and 2% tolerance.
contract WbtcPricedFeedsForkTest is Test {
    uint256 constant FORK_BLOCK = 26279532;
    uint256 constant STALE_PERIOD = 90000;
    uint256 constant REDEEM_FEE = 15; // bps

    ICurveStableSwapNG constant POOL = ICurveStableSwapNG(0x66039342C66760874047c36943B1e2d8300363BB);
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant HEMIBTC = 0x06ea695B91700071B161A434fED42D1DcbAD9f00;
    AggregatorV2V3Interface constant WBTC_BTC_FEED =
        AggregatorV2V3Interface(0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23);
    AggregatorV2V3Interface constant CBBTC_BTC_DERIVED_FEED =
        AggregatorV2V3Interface(0x33F1E44DB47400C9BD6221962712D882Adb8fFA6);
    AggregatorV2V3Interface constant HEMIBTC_BTC_RATE_FEED =
        AggregatorV2V3Interface(0x7Ff41654D1551F01E622e2b1050EA027a3A6C9dc);
    AggregatorV2V3Interface constant WBTC_UNIT_FEED =
        AggregatorV2V3Interface(0x032A35daDA672B394525881f789a3B4E7734C76C);

    // At FORK_BLOCK
    int256 constant CBBTC_EMA = 1.001603119651729182e18;
    int256 constant HEMIBTC_EMA = 1.000913829757465373e18;

    DerivedPriceFeedAdapter cbBtcChainlink;
    CurveStableSwapNGEmaFeedAdapter cbBtcEma;
    MinPriceFeedAdapter cbBtcFeed;
    DerivedPriceFeedAdapter hemiBtcChainlink;
    MinPriceFeedAdapter hemiBtcFeed;

    PeggedToken vetBTC;
    Treasury treasury;
    Gateway gateway;
    address alice = makeAddr("alice");

    function setUp() public {
        vm.createSelectFork("ethereum", FORK_BLOCK);

        cbBtcChainlink = new DerivedPriceFeedAdapter(CBBTC_BTC_DERIVED_FEED, WBTC_BTC_FEED, 8);
        cbBtcEma = new CurveStableSwapNGEmaFeedAdapter(POOL, cbBTC, 1, WBTC, 0, WBTC_UNIT_FEED);
        cbBtcFeed = new MinPriceFeedAdapter(cbBtcChainlink, cbBtcEma, 18);
        hemiBtcChainlink = new DerivedPriceFeedAdapter(HEMIBTC_BTC_RATE_FEED, WBTC_BTC_FEED, 18);
        hemiBtcFeed = new MinPriceFeedAdapter(
            hemiBtcChainlink, new CurveStableSwapNGEmaFeedAdapter(POOL, HEMIBTC, 2, WBTC, 0, WBTC_UNIT_FEED), 18
        );

        vetBTC = new PeggedToken("Vetro BTC", "vetBTC", address(this));
        treasury = deployTreasury(address(vetBTC), address(this));
        vetBTC.updateTreasury(address(treasury));
        treasury.grantRole(treasury.KEEPER_ROLE(), address(this));
        treasury.grantRole(treasury.MAINTAINER_ROLE(), address(this));
        treasury.grantRole(treasury.UMM_ROLE(), address(this));
        gateway = Gateway(
            address(
                new ERC1967Proxy(
                    address(new Gateway()),
                    abi.encodeWithSelector(Gateway.initialize.selector, address(vetBTC), type(uint256).max, 7 days)
                )
            )
        );
        vetBTC.updateGateway(address(gateway));
        gateway.setWithdrawalDelayEnabled(false);
        treasury.updatePriceTolerance(200);

        _whitelist(WBTC, address(WBTC_UNIT_FEED));
        _whitelist(cbBTC, address(cbBtcFeed));
        _whitelist(HEMIBTC, address(hemiBtcFeed));
    }

    function _whitelist(address token_, address oracle_) private {
        treasury.addToWhitelist(token_, address(new PassthroughVault(IERC20(token_))), oracle_, STALE_PERIOD);
        gateway.updateRedeemFee(token_, REDEEM_FEE);
    }

    function _deposit(address token_, uint256 amount_) private returns (uint256 _minted) {
        deal(token_, alice, amount_);
        vm.startPrank(alice);
        IERC20(token_).approve(address(gateway), amount_);
        _minted = gateway.deposit(token_, amount_, 0, alice);
        vm.stopPrank();
    }

    function _answer(AggregatorV2V3Interface feed_) private view returns (int256 _price, uint256 _updatedAt) {
        (, _price,, _updatedAt,) = feed_.latestRoundData();
    }

    function _dumpHemiBtc(uint256 amount_) private {
        deal(HEMIBTC, address(this), amount_);
        IERC20(HEMIBTC).approve(address(POOL), amount_);
        ICurveExchange(address(POOL)).exchange(2, 0, amount_, 0);
    }

    function test_feeds_productionValues() public view {
        (int256 _derived, uint256 _derivedAt) = _answer(CBBTC_BTC_DERIVED_FEED);
        (int256 _wbtcBtc, uint256 _wbtcBtcAt) = _answer(WBTC_BTC_FEED);
        (int256 _chainlinkLeg, uint256 _chainlinkLegAt) = _answer(cbBtcChainlink);
        assertEq(_chainlinkLeg, (_derived * 1e8) / _wbtcBtc, "cbBTC/WBTC = cbBTC/BTC / WBTC/BTC");
        assertEq(_chainlinkLegAt, _derivedAt < _wbtcBtcAt ? _derivedAt : _wbtcBtcAt);

        (int256 _cbBtc, uint256 _cbBtcAt) = _answer(cbBtcFeed);
        assertGt(_chainlinkLeg * 1e10, CBBTC_EMA, "Chainlink leg lags above the EMA");
        assertEq(_cbBtc, CBBTC_EMA, "min picks the EMA");
        assertEq(_cbBtcAt, _chainlinkLegAt, "cbBTC goes stale with its Chainlink leg");
        assertEq(cbBtcFeed.decimals(), 18);

        (int256 _rate, uint256 _rateAt) = _answer(HEMIBTC_BTC_RATE_FEED);
        (int256 _hemiChainlinkLeg, uint256 _hemiChainlinkLegAt) = _answer(hemiBtcChainlink);
        assertEq(_rate, 1e18, "exchange rate reads par");
        assertEq(_hemiChainlinkLeg, (_rate * 1e8) / _wbtcBtc, "hemiBTC/WBTC = hemiBTC/BTC / WBTC/BTC");
        assertEq(_hemiChainlinkLegAt, _rateAt < _wbtcBtcAt ? _rateAt : _wbtcBtcAt);

        (int256 _hemiBtc, uint256 _hemiBtcAt) = _answer(hemiBtcFeed);
        assertGt(_hemiChainlinkLeg, HEMIBTC_EMA, "WBTC below BTC lifts the Chainlink leg above the EMA");
        assertEq(_hemiBtc, HEMIBTC_EMA, "min picks the EMA");
        assertEq(_hemiBtcAt, _hemiChainlinkLegAt, "hemiBTC goes stale with its Chainlink leg");
    }

    function test_depositAndRedeem_atProductionPrices() public {
        // All three at or above par: deposits mint at par
        assertEq(_deposit(WBTC, 1e8), 1e18);
        assertEq(_deposit(cbBTC, 1e8), 1e18);
        assertEq(_deposit(HEMIBTC, 1e8), 1e18);

        // Redeems pay at the price above par, net of the fee
        vm.startPrank(alice);
        uint256 _wbtcOut = gateway.redeem(WBTC, 1e18, 0, alice);
        uint256 _cbBtcPreview = gateway.previewRedeem(cbBTC, 1e18);
        uint256 _cbBtcOut = gateway.redeem(cbBTC, 1e18, 0, alice);
        uint256 _hemiBtcOut = gateway.redeem(HEMIBTC, 1e18, 0, alice);
        vm.stopPrank();

        assertEq(_wbtcOut, 1e8 * (10_000 - REDEEM_FEE) / 10_000);
        assertEq(_cbBtcOut, _cbBtcPreview, "preview matches execution");
        assertApproxEqAbs(_cbBtcOut, _wbtcOut * 1e18 / uint256(CBBTC_EMA), 1);
        assertApproxEqAbs(_hemiBtcOut, _wbtcOut * 1e18 / uint256(HEMIBTC_EMA), 1);
    }

    function test_harvest_paysExactExcess() public {
        _deposit(WBTC, 5e8);
        _deposit(cbBTC, 5e8);
        _deposit(HEMIBTC, 5e8);
        deal(WBTC, address(treasury), IERC20(WBTC).balanceOf(address(treasury)) + 0.01e8);

        assertEq(treasury.harvest(WBTC, address(this)), 0.01e8);
        assertEq(treasury.reserve(), vetBTC.totalSupply(), "reserve lands on supply");
    }

    function test_cbBtc_staleAt90000() public {
        _assertStaleAt90000(cbBTC, address(cbBtcFeed));
    }

    function test_hemiBtc_staleAt90000() public {
        _assertStaleAt90000(HEMIBTC, address(hemiBtcFeed));
    }

    function _assertStaleAt90000(address token_, address feed_) private {
        (, uint256 _updatedAt) = _answer(AggregatorV2V3Interface(feed_));
        vm.warp(_updatedAt + STALE_PERIOD - 1);
        treasury.getPrice(token_);

        vm.warp(_updatedAt + STALE_PERIOD);
        vm.expectRevert(abi.encodeWithSelector(Treasury.StalePrice.selector, feed_));
        treasury.getPrice(token_);
    }

    /// @notice A bridge rate cut lowers the hemiBTC price even when nobody trades in the Curve pool
    function test_hemiBtc_rateCutLowersPrice() public {
        (uint80 _roundId,,, uint256 _updatedAt, uint80 _answeredInRound) = HEMIBTC_BTC_RATE_FEED.latestRoundData();
        vm.mockCall(
            address(HEMIBTC_BTC_RATE_FEED),
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(_roundId, int256(0.99e18), _updatedAt, _updatedAt, _answeredInRound)
        );
        (int256 _wbtcBtc,) = _answer(WBTC_BTC_FEED);
        (uint256 _price,) = treasury.getPrice(HEMIBTC);
        assertEq(_price, uint256((int256(0.99e18) * 1e8) / _wbtcBtc));
        assertLt(gateway.previewDeposit(HEMIBTC, 1e8), 1e18, "mints below par");
    }

    /// @notice A held dump first lowers the hemiBTC mint price below par, then takes it out of tolerance
    function test_hemiBtc_heldDumpLowersThenBlocksMint() public {
        _dumpHemiBtc(10e8);
        assertEq(gateway.previewDeposit(HEMIBTC, 1e8), 1e18, "unchanged in the dump block");

        vm.roll(block.number + 50);
        vm.warp(block.timestamp + 600);
        uint256 _minted = gateway.previewDeposit(HEMIBTC, 1e8);
        assertLt(_minted, 1e18, "below par after 10 minutes");
        assertGt(_minted, 0.98e18);

        vm.roll(block.number + 150);
        vm.warp(block.timestamp + 1800);
        vm.expectPartialRevert(Treasury.PriceExceedTolerance.selector);
        gateway.previewDeposit(HEMIBTC, 1e8);
    }
}
