// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV2V3Interface} from "@chainlink/contracts/interfaces/feeds/AggregatorV2V3Interface.sol";
import {CurveStableSwapNGEmaFeedAdapter, ICurveStableSwapNG} from "src/CurveStableSwapNGEmaFeedAdapter.sol";
import {MinPriceFeedAdapter} from "src/MinPriceFeedAdapter.sol";
import {Treasury} from "src/Treasury.sol";
import {Gateway} from "src/Gateway.sol";
import {cbBTC, VETBTC_TREASURY, VETBTC_GATEWAY} from "test/helpers/Address.ethereum.sol";

interface ICurveExchange {
    function exchange(int128 i, int128 j, uint256 dx, uint256 minDy) external returns (uint256);
    function get_p(uint256 i) external view returns (uint256);
}

/// @dev cbBTC/BTC and hemiBTC/BTC as min(primary feed, Curve EMA x WBTC/BTC) on the live vetBTC Treasury.
contract CurveStableSwapNGEmaFeedAdapterForkTest is Test {
    uint256 constant FORK_BLOCK = 26279532;

    ICurveStableSwapNG constant POOL = ICurveStableSwapNG(0x66039342C66760874047c36943B1e2d8300363BB); // WBTC/cbBTC/hemiBTC
    AggregatorV2V3Interface constant WBTC_BTC_FEED =
        AggregatorV2V3Interface(0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23);
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant HEMIBTC = 0x06ea695B91700071B161A434fED42D1DcbAD9f00;
    AggregatorV2V3Interface constant HEMIBTC_BTC_RATE_FEED =
        AggregatorV2V3Interface(0x7Ff41654D1551F01E622e2b1050EA027a3A6C9dc);
    AggregatorV2V3Interface constant CBBTC_BTC_DERIVED_FEED =
        AggregatorV2V3Interface(0x33F1E44DB47400C9BD6221962712D882Adb8fFA6);

    // At FORK_BLOCK: EMA vs WBTC x WBTC/BTC 0.99819999
    int256 constant CBBTC_BTC = 0.999800224020324872e18; // 1.001603119651729182 cbBTC/WBTC
    int256 constant HEMIBTC_BTC = 0.999112174854763637e18; // 1.000913829757465373 hemiBTC/WBTC

    Treasury treasury = Treasury(VETBTC_TREASURY);
    Gateway gateway = Gateway(VETBTC_GATEWAY);

    CurveStableSwapNGEmaFeedAdapter cbBtcEma;
    CurveStableSwapNGEmaFeedAdapter hemiBtcEma;
    MinPriceFeedAdapter cbBtcFeed;
    MinPriceFeedAdapter hemiBtcFeed;

    function setUp() public {
        vm.createSelectFork("ethereum", FORK_BLOCK);
        cbBtcEma = new CurveStableSwapNGEmaFeedAdapter(POOL, cbBTC, 1, WBTC, 0, WBTC_BTC_FEED);
        hemiBtcEma = new CurveStableSwapNGEmaFeedAdapter(POOL, HEMIBTC, 2, WBTC, 0, WBTC_BTC_FEED);
        cbBtcFeed = new MinPriceFeedAdapter(CBBTC_BTC_DERIVED_FEED, cbBtcEma, 8);
        hemiBtcFeed = new MinPriceFeedAdapter(HEMIBTC_BTC_RATE_FEED, hemiBtcEma, 18);
    }

    function _answer(AggregatorV2V3Interface feed_) private view returns (int256 _price) {
        (, _price,,,) = feed_.latestRoundData();
    }

    // ── adapter ──────────────────────────────────────────────────────────────

    function test_constructor_revertIfSameCoin() public {
        vm.expectRevert(CurveStableSwapNGEmaFeedAdapter.SameCoin.selector);
        new CurveStableSwapNGEmaFeedAdapter(POOL, HEMIBTC, 2, HEMIBTC, 2, WBTC_BTC_FEED);
    }

    function test_constructor_revertIfCoinNotAtIndex() public {
        vm.expectRevert(CurveStableSwapNGEmaFeedAdapter.CoinMismatch.selector);
        new CurveStableSwapNGEmaFeedAdapter(POOL, HEMIBTC, 1, WBTC, 0, WBTC_BTC_FEED);
        vm.expectRevert(CurveStableSwapNGEmaFeedAdapter.CoinMismatch.selector);
        new CurveStableSwapNGEmaFeedAdapter(POOL, HEMIBTC, 2, cbBTC, 0, WBTC_BTC_FEED);
    }

    function test_constructor_revertIfIndexPastLastCoin() public {
        vm.expectRevert();
        new CurveStableSwapNGEmaFeedAdapter(POOL, HEMIBTC, 3, WBTC, 0, WBTC_BTC_FEED);
    }

    function test_constructor_revertIfZeroAddress() public {
        vm.expectRevert(CurveStableSwapNGEmaFeedAdapter.ZeroAddress.selector);
        new CurveStableSwapNGEmaFeedAdapter(ICurveStableSwapNG(address(0)), HEMIBTC, 2, WBTC, 0, WBTC_BTC_FEED);
        vm.expectRevert(CurveStableSwapNGEmaFeedAdapter.ZeroAddress.selector);
        new CurveStableSwapNGEmaFeedAdapter(POOL, address(0), 2, WBTC, 0, WBTC_BTC_FEED);
        vm.expectRevert(CurveStableSwapNGEmaFeedAdapter.ZeroAddress.selector);
        new CurveStableSwapNGEmaFeedAdapter(POOL, HEMIBTC, 2, address(0), 0, WBTC_BTC_FEED);
        vm.expectRevert(CurveStableSwapNGEmaFeedAdapter.ZeroAddress.selector);
        new CurveStableSwapNGEmaFeedAdapter(POOL, HEMIBTC, 2, WBTC, 0, AggregatorV2V3Interface(address(0)));
    }

    /// @notice Out of scope by design: with a rate-oracle coin the NG EMA is rate-adjusted, so weETH reads ~1.0 WETH
    ///         while it trades at ~1.106 WETH.
    function test_rateOracleCoinIsNotMarketPrice() public {
        CurveStableSwapNGEmaFeedAdapter _weeth = new CurveStableSwapNGEmaFeedAdapter(
            ICurveStableSwapNG(0xDB74dfDD3BB46bE8Ce6C33dC9D82777BCFc3dEd5),
            0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee,
            1,
            0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
            0,
            WBTC_BTC_FEED
        );
        assertApproxEqRel(_weeth.emaRatio(), 1e18, 0.001e18);
    }

    function test_metadata() public view {
        assertEq(address(hemiBtcEma.pool()), address(POOL));
        assertEq(hemiBtcEma.baseIndex(), 2);
        assertEq(hemiBtcEma.quoteIndex(), 0);
        assertEq(address(hemiBtcEma.quoteFeed()), address(WBTC_BTC_FEED));
        assertEq(cbBtcEma.baseIndex(), 1);
        assertEq(cbBtcEma.decimals(), 18);
        assertEq(cbBtcEma.description(), string.concat("Curve EMA x ", WBTC_BTC_FEED.description()));
        assertEq(cbBtcEma.version(), 1);
        assertEq(cbBtcEma.latestRound(), 1);
    }

    // ── quote coin other than coin 0 ─────────────────────────────────────────

    function test_emaRatio_crossRateBetweenNonZeroIndices() public {
        // hemiBTC priced in cbBTC: P_hemi / P_cbBTC, both against WBTC
        CurveStableSwapNGEmaFeedAdapter _hemiInCbBtc =
            new CurveStableSwapNGEmaFeedAdapter(POOL, HEMIBTC, 2, cbBTC, 1, CBBTC_BTC_DERIVED_FEED);
        uint256 _expected = (POOL.price_oracle(1) * 1e18) / POOL.price_oracle(0);
        assertEq(_hemiInCbBtc.emaRatio(), _expected);

        (, int256 _cbBtcBtc,,,) = CBBTC_BTC_DERIVED_FEED.latestRoundData();
        assertEq(_answer(_hemiInCbBtc), int256((_expected * uint256(_cbBtcBtc)) / 1e8));
    }

    function test_emaRatio_baseIsCoin0() public {
        // WBTC priced in hemiBTC is the inverse of the hemiBTC EMA
        CurveStableSwapNGEmaFeedAdapter _wbtcInHemi =
            new CurveStableSwapNGEmaFeedAdapter(POOL, WBTC, 0, HEMIBTC, 2, HEMIBTC_BTC_RATE_FEED);
        assertEq(_wbtcInHemi.emaRatio(), 1e36 / POOL.price_oracle(1));
    }

    function test_emaRatio_crossRateConsistentWithCoin0Route() public {
        // hemiBTC via cbBTC x cbBTC via WBTC == hemiBTC via WBTC (up to rounding)
        CurveStableSwapNGEmaFeedAdapter _hemiInCbBtc =
            new CurveStableSwapNGEmaFeedAdapter(POOL, HEMIBTC, 2, cbBTC, 1, WBTC_BTC_FEED);
        assertApproxEqAbs((_hemiInCbBtc.emaRatio() * cbBtcEma.emaRatio()) / 1e18, hemiBtcEma.emaRatio(), 2);
    }

    function test_latestRoundData_emaTimesWbtcBtc() public view {
        (uint80 _roundId, int256 _hemiBtc,,, uint80 _answeredInRound) = hemiBtcEma.latestRoundData();
        assertEq(_hemiBtc, HEMIBTC_BTC);
        assertEq(_answer(cbBtcEma), CBBTC_BTC);
        assertEq(_roundId, 1);
        assertEq(_answeredInRound, 1);
        assertEq(hemiBtcEma.latestAnswer(), HEMIBTC_BTC);
    }

    function test_latestRoundData_updatedAtIsWbtcBtcFeed() public view {
        (,,, uint256 _wbtcAt,) = hemiBtcEma.quoteFeed().latestRoundData();
        (,, uint256 _startedAt, uint256 _updatedAt,) = hemiBtcEma.latestRoundData();
        assertEq(_updatedAt, _wbtcAt);
        assertEq(_startedAt, _wbtcAt);
        assertEq(hemiBtcEma.latestTimestamp(), _wbtcAt);
    }

    function test_latestRoundData_revertIfWbtcBtcNotPositive() public {
        vm.mockCall(
            address(hemiBtcEma.quoteFeed()),
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(0), block.timestamp, block.timestamp, uint80(1))
        );
        vm.expectRevert(CurveStableSwapNGEmaFeedAdapter.InvalidPrice.selector);
        hemiBtcEma.latestRoundData();
    }

    function test_latestRoundData_revertIfEmaIsZero() public {
        vm.mockCall(
            address(hemiBtcEma.pool()),
            abi.encodeWithSelector(ICurveStableSwapNG.price_oracle.selector, 1),
            abi.encode(0)
        );
        vm.expectRevert(CurveStableSwapNGEmaFeedAdapter.InvalidPrice.selector);
        hemiBtcEma.latestRoundData();
    }

    function test_historicalRounds_revert() public {
        vm.expectRevert(CurveStableSwapNGEmaFeedAdapter.HistoricalRoundsNotSupported.selector);
        hemiBtcEma.getRoundData(1);
        vm.expectRevert(CurveStableSwapNGEmaFeedAdapter.HistoricalRoundsNotSupported.selector);
        hemiBtcEma.getAnswer(1);
        vm.expectRevert(CurveStableSwapNGEmaFeedAdapter.HistoricalRoundsNotSupported.selector);
        hemiBtcEma.getTimestamp(1);
    }

    /// @notice A same-block dump moves spot past the 2% tolerance but cannot move the EMA-based price.
    function test_sameBlockSandwichDoesNotMovePrice() public {
        address _pool = address(hemiBtcEma.pool());
        uint256 _spotBefore = ICurveExchange(_pool).get_p(1);

        uint256 _amount = 10e8;
        deal(HEMIBTC, address(this), _amount);
        IERC20(HEMIBTC).approve(_pool, _amount);
        ICurveExchange(_pool).exchange(2, 0, _amount, 0);

        assertLt(ICurveExchange(_pool).get_p(1), (_spotBefore * 98) / 100, "spot moved > 2%");
        assertEq(_answer(hemiBtcEma), HEMIBTC_BTC, "EMA-based price unchanged in the same block");
    }

    // ── paired with the primary feeds ────────────────────────────────────────

    function test_min_hemiBtcPricedAtMarketDiscount() public view {
        assertEq(_answer(HEMIBTC_BTC_RATE_FEED), 1e18, "exchange-rate feed reads par");
        assertEq(_answer(hemiBtcFeed), HEMIBTC_BTC, "min picks the market discount");
    }

    function test_min_cbBtcLagCappedByEma() public view {
        assertGt(_answer(CBBTC_BTC_DERIVED_FEED), 1e8, "derived feed reads above par on lag");
        assertEq(_answer(cbBtcFeed), CBBTC_BTC / 1e10, "min picks the EMA, scaled to 8 decimals");
    }

    /// @notice Wired into the live Treasury, hemiBTC deposits mint at the market price instead of par.
    function test_treasuryAndGatewayUseAdapter() public {
        (,, uint256 _hemiStale,,,) = treasury.tokenConfig(HEMIBTC);
        (,, uint256 _cbStale,,,) = treasury.tokenConfig(cbBTC);
        uint256 _parMint = gateway.previewDeposit(HEMIBTC, 1e8);

        bytes32 _maintainer = treasury.MAINTAINER_ROLE();
        vm.prank(treasury.defaultAdmin());
        treasury.grantRole(_maintainer, address(this));
        treasury.updateOracle(HEMIBTC, address(hemiBtcFeed), _hemiStale);
        treasury.updateOracle(cbBTC, address(cbBtcFeed), _cbStale);

        (uint256 _price, uint256 _unit) = treasury.getPrice(HEMIBTC);
        assertEq(_price, uint256(HEMIBTC_BTC));
        assertEq(_unit, 1e18);

        assertEq(_parMint, 1e18, "par mint before");
        assertEq(
            gateway.previewDeposit(HEMIBTC, 1e8),
            (1e8 * uint256(HEMIBTC_BTC) / 1e18) * 1e10,
            "market-price mint after, computed in hemiBTC decimals"
        );

        // reserve() still prices every token through the new feeds
        treasury.reserve();
    }
}
